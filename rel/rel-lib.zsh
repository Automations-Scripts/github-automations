rel_ctx_load_repo() {
  emulate -L zsh
  set -u
  set -o pipefail

  typeset -g REL_OWNER REL_REPO REL_REPO_FULL
  REL_OWNER="$(gh repo view --json owner -q .owner.login)"
  REL_REPO="$(gh repo view --json name -q .name)"
  REL_REPO_FULL="${REL_OWNER}/${REL_REPO}"

  # true/false
  REL_REPO_PRIVATE="$(gh repo view --json isPrivate -q .isPrivate)"
}

rel_project_visibility_for_repo() {
  emulate -L zsh
  set -u
  set -o pipefail

  # GitHub Projects v2 usa PUBLIC|PRIVATE (caps)
  if [[ "${REL_REPO_PRIVATE:-false}" == "true" ]]; then
    echo "PRIVATE"
  else
    echo "PUBLIC"
  fi
}

rel_ctx_load_open_milestone() {
  emulate -L zsh
  set -euo pipefail

  rel_ctx_load_repo

  typeset -g REL_PROJ REL_PROJ_TITLE

  local owner_type projects_json linked
  owner_type="$(gh api "repos/$REL_REPO_FULL" -q '.owner.type')"  # User|Organization

  # Lista Projects v2 do OWNER (org ou user), com repos linkados
  if [[ "$owner_type" == "Organization" ]]; then
    projects_json="$(
      gh api graphql -f query='
        query($login:String!) {
          organization(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                closed
                repositories(first: 100) { nodes { nameWithOwner } }
              }
            }
          }
        }' -F login="$REL_OWNER" \
      | jq -c '.data.organization.projectsV2.nodes'
    )"
  else
    projects_json="$(
      gh api graphql -f query='
        query($login:String!) {
          user(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                closed
                repositories(first: 100) { nodes { nameWithOwner } }
              }
            }
          }
        }' -F login="$REL_OWNER" \
      | jq -c '.data.user.projectsV2.nodes'
    )"
  fi

  # Mantém só projects linkados a ESTE repo (evita "fantasmas")
  linked="$(
    echo "$projects_json" | jq -c --arg REPO "$REL_REPO_FULL" '
      map(
        select((.repositories.nodes // []) | map(.nameWithOwner) | index($REPO))
      )
    '
  )"

  # Pega o dev-line aberto mais antigo: vX.Y.x (closed=false)
  REL_PROJ="$(
    echo "$linked" | jq -r '
      map(select(.closed == false))
      | map(select((.title // "") | test("^v[0-9]+\\.[0-9]+\\.x$")))
      | sort_by(.number)
      | .[0].number // empty
    '
  )"

  if [[ -z "${REL_PROJ:-}" ]]; then
    echo "No open Project (development line) with title vX.Y.x found for $REL_REPO_FULL."
    return 1
  fi

  REL_PROJ_TITLE="$(
    gh project view "$REL_PROJ" --owner "$REL_OWNER" --format json |
      jq -r '.title'
  )"
}

rel_ctx_load_last_tag() {
  emulate -L zsh
  set -u
  set -o pipefail

  typeset -g REL_LAST_TAG REL_MAJOR REL_MINOR REL_PATCH

  # pega tags vX.Y ou vX.Y.Z
  REL_LAST_TAG="$(
    gh api "repos/$REL_REPO_FULL/tags" --paginate -q '.[].name' |
      grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' |
      sort -V |
      tail -n 1 || true
  )"
  [[ -z "${REL_LAST_TAG:-}" ]] && REL_LAST_TAG="v0.0"

  local base="${REL_LAST_TAG#v}"
  local a b c
  IFS='.' read -r a b c <<< "$base"

  REL_MAJOR="$a"
  REL_MINOR="$b"
  REL_PATCH="${c:-}"   # vazio quando for release vX.Y
}

# ---------- Project helpers ----------

rel_items_json() {
  emulate -L zsh
  set -u
  set -o pipefail
  gh project item-list "$REL_PROJ" --owner "$REL_OWNER" --format json
}

rel_try_set_status() {
  emulate -L zsh
  set -u
  set -o pipefail

  local project_number="$1"
  local item_id="$2"
  local new_status="$3"   # Avoid using the name "status"

  local project_id fields_json status_field_id option_id

  project_id="$(
    gh project view "$project_number" --owner "$REL_OWNER" --format json |
      jq -r '.id'
  )"

  fields_json="$(
    gh project field-list "$project_number" --owner "$REL_OWNER" --format json
  )"

  status_field_id="$(
    echo "$fields_json" |
      jq -r '.fields[] | select(.name=="Status") | .id' |
      head -n1
  )"

  [[ -z "${status_field_id:-}" || "$status_field_id" == "null" ]] && return 0

  option_id="$(
    echo "$fields_json" |
      jq -r --arg S "$new_status" '
        .fields[] | select(.id=="'"$status_field_id"'")
        | .options[] | select(.name==$S) | .id
      ' |
      head -n1
  )"

  [[ -z "${option_id:-}" || "$option_id" == "null" ]] && return 0

  gh project item-edit \
    --project-id "$project_id" \
    --id "$item_id" \
    --field-id "$status_field_id" \
    --single-select-option-id "$option_id" \
    >/dev/null 2>&1 || true
}

rel_mark_all_done() {
  emulate -L zsh
  set -u
  set -o pipefail

  local project_number="$1"
  local json repo_full
  json="$(gh project item-list "$project_number" --owner "$REL_OWNER" --format json)"

  # repo atual (pra fechar issues)
  local owner repo
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"
  repo_full="$owner/$repo"

  # percorre itens do project (id + issue number se existir)
  echo "$json" | jq -r '
    .items[]
    | [.id, (.content.number? // empty)]
    | @tsv
  ' | while IFS=$'\t' read -r item_id issue_no; do
    [[ -z "$item_id" ]] && continue

    # 1) Status do Project -> Done
    rel_try_set_status "$project_number" "$item_id" "Done"

    # 2) Se for Issue de verdade, fecha (isso liga o "completed" ✓)
    if [[ -n "${issue_no:-}" ]]; then
      gh issue close "$issue_no" --repo "$repo_full" >/dev/null || true
    fi
  done
} 

rel_issue_comment() {
  emulate -L zsh
  set -u
  set -o pipefail

  local issue_no="$1"
  local body="$2"

  gh issue comment "$issue_no" --repo "$REL_REPO_FULL" --body "$body" >/dev/null
}

rel_create_release() {
  emulate -L zsh
  set -u
  set -o pipefail

  local tag="$1"
  local notes="$2"

  echo "[info] $REL_REPO_FULL"
  echo "[info] Tag to create: $REL_LAST_TAG -> $tag"

  gh release create "$tag" --title "$tag" --notes "$notes" > /dev/null
  echo "[info] Release created: $tag"
}

rel_close_project() {
  emulate -L zsh
  set -euo pipefail

  local proj="${1:-$REL_PROJ}"
  local title="${2:-$REL_PROJ_TITLE}"

  gh project close "$proj" --owner "$REL_OWNER"
  echo "Project closed: ${title:-"(unknown)"} (#$proj)"
}

rel_maybe_open_next_project() {
  emulate -L zsh
  set -u
  set -o pipefail

  local next_title="$1"

  echo -n "Open next Project (${next_title})? [y/N]: "
  local ans
  IFS= read -r ans || true

  case "${ans:-}" in
    y|Y|yes|YES)
      local next_proj
      next_proj="$(
        gh project create --owner "$REL_OWNER" --title "$next_title" --format json |
          jq -r '.number'
      )"
     
      rel_link_project_to_repo "$next_proj"

      # Ajusta a visibilidade do Project conforme o repo atual
      local vis
      vis="$(rel_project_visibility_for_repo)"
      gh project edit "$next_proj" --owner "$REL_OWNER" --visibility "$vis" >/dev/null

      echo "New Project opened: $next_title (#$next_proj) visibility=$vis"
      ;;
    *)
      echo "Ok. No new Project created."
      ;;
  esac
}

rel_link_project_to_repo() {
  emulate -L zsh
  set -euo pipefail

  local project_number="$1"
  local repo_full="${2:-$REL_REPO_FULL}"

  gh project link "$project_number" --owner "$REL_OWNER" --repo "$repo_full" >/dev/null
}

rel_create_tag() {
  emulate -L zsh
  set -u
  set -o pipefail

  local tag="$1"

  echo "[info] $REL_REPO_FULL"
  echo "[info] Tag to create: $REL_LAST_TAG -> $tag"

  # If tag already exists, stop (avoid rewriting history)
  if gh api "repos/$REL_REPO_FULL/git/ref/tags/$tag" >/dev/null 2>&1; then
    echo "[warn] Tag already exists: $tag"
    return 1
  fi

  # Tag target = default branch HEAD (source of truth on GitHub)
  local default_branch sha
  default_branch="$(gh api "repos/$REL_REPO_FULL" -q '.default_branch')"
  sha="$(gh api "repos/$REL_REPO_FULL/git/ref/heads/$default_branch" -q '.object.sha')"

  gh api -X POST "repos/$REL_REPO_FULL/git/refs" \
    -f "ref=refs/tags/$tag" \
    -f "sha=$sha" \
    >/dev/null

  echo "[info] Tag created: $tag (at $default_branch)"
}

rel_issue_last_patch_tag() {
  emulate -L zsh
  set -u
  set -o pipefail

  local issue_no="$1"

  # Grab the last comment that matches: "Tagged in vX.Y.Z"
  gh issue view "$issue_no" --repo "$REL_REPO_FULL" --json comments \
    | jq -r '
      [.comments[].body
        | select(test("^Tagged in v[0-9]+\\.[0-9]+\\.[0-9]+"))
      ] | last // empty
    ' \
    | sed -E 's/^Tagged in (v[0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

rel_build_release_notes_from_project() {
  emulate -L zsh
  set -u
  set -o pipefail

  local release_line="$1"  # e.g. "v0.5"
  local json
  json="$(rel_items_json)"

  echo "See project ${release_line} for details."
  echo
  echo "## Shipped items"
  echo

  echo "$json" | jq -r '
    .items[]
    | select(((.status // "No status") | ascii_downcase) == "done")
    | select(.content.number? != null)
    | "\(.content.number)\t\(.content.title // .title // "Untitled")"
  ' | while IFS=$'\t' read -r issue_no title; do
    local tag
    tag="$(rel_issue_last_patch_tag "$issue_no" || true)"
    if [[ -n "${tag:-}" ]]; then
      echo "- #${issue_no} ${title} — **${tag}**"
    else
      echo "- #${issue_no} ${title}"
    fi
  done
}

rel_project_id() {
  emulate -L zsh
  set -u
  set -o pipefail
  local project_number="$1"
  gh project view "$project_number" --owner "$REL_OWNER" --format json | jq -r '.id'
}

rel_finalize_done_items() {
  emulate -L zsh
  set -u
  set -o pipefail

  local project_number="$1"
  local json repo_full
  json="$(gh project item-list "$project_number" --owner "$REL_OWNER" --format json)"

  repo_full="$REL_REPO_FULL"

  echo "$json" | jq -r '
    .items[]
    | select((.status // "No status") | ascii_downcase == "done")
    | [.id, (.content.number? // empty)]
    | @tsv
  ' | while IFS=$'\t' read -r item_id issue_no; do
    [[ -z "$item_id" ]] && continue

    # garante status Done (idempotente)
    rel_try_set_status "$project_number" "$item_id" "Done"

    # fecha issue real (liga o "completed" ✓)
    if [[ -n "${issue_no:-}" ]]; then
      gh issue close "$issue_no" --repo "$repo_full" >/dev/null || true
    fi
  done
}

rel_project_has_backlog() {
  emulate -L zsh
  set -u
  set -o pipefail

  local project_number="$1"
  local json
  json="$(gh project item-list "$project_number" --owner "$REL_OWNER" --format json)"

  echo "$json" | jq -e '
    any(.items[];
      ((.status // "No status") | ascii_downcase) != "done"
    )
  ' >/dev/null
}

rel_move_backlog_to_project() {
  emulate -L zsh
  set -u
  set -o pipefail

  local from_proj="$1"   # projeto "vX.Y (released)" (era a dev line anterior)
  local to_proj="$2"     # novo "vX.Y.x"

  # IDs GraphQL (necessário para remover item do projeto antigo)
  local from_project_id
  from_project_id="$(
    gh project view "$from_proj" --owner "$REL_OWNER" --format json | jq -r '.id'
  )"

  # Pega backlog: item_id + issue_url + status + issue_number
  local json
  json="$(gh project item-list "$from_proj" --owner "$REL_OWNER" --format json)"

  echo "$json" | jq -r '
    .items[]
    | select(((.status // "No status") | ascii_downcase) != "done")
    | [
        .id,
        (.content.url // ""),
        (.status // "Todo"),
        (.content.number? // empty)
      ]
    | @tsv
  ' | while IFS=$'\t' read -r item_id url st issue_no; do
    [[ -z "${item_id:-}" ]] && continue
    [[ -z "${url:-}" ]] && continue

    # 1) adiciona ao novo projeto
    gh project item-add "$to_proj" --owner "$REL_OWNER" --url "$url" >/dev/null

    # 2) acha o NOVO item_id no projeto destino pelo issue number e replica status
    if [[ -n "${issue_no:-}" ]]; then
      local to_json new_item_id
      to_json="$(gh project item-list "$to_proj" --owner "$REL_OWNER" --format json)"
      new_item_id="$(
        echo "$to_json" | jq -r --argjson N "$issue_no" '
          .items[]
          | select(.content.number? == $N)
          | .id
        ' | head -n1
      )"

      if [[ -n "${new_item_id:-}" && "${new_item_id:-}" != "null" ]]; then
        # st pode vir "Todo" ou "In Progress" — e precisa existir no projeto destino
        rel_try_set_status "$to_proj" "$new_item_id" "$st"
      fi
    fi

    # 3) remove do projeto antigo (pra não ficar pendência em "released")
    gh api graphql -f query='
      mutation($projectId:ID!, $itemId:ID!){
        deleteProjectV2Item(input:{projectId:$projectId, itemId:$itemId}) {
          deletedItemId
        }
      }' -F projectId="$from_project_id" -F itemId="$item_id" >/dev/null || true
  done
}

rel_open_next_project_auto() {
  emulate -L zsh
  set -euo pipefail

  local next_title="$1"

  local next_proj
  next_proj="$(
    gh project create --owner "$REL_OWNER" --title "$next_title" --format json |
      jq -r '.number'
  )"

  rel_link_project_to_repo "$next_proj" "$REL_REPO_FULL"

  # valida (se falhar aqui, você pega na hora)
  local repos
  repos="$(gh project view "$next_proj" --owner "$REL_OWNER" --format json | jq -r '.repositories')"
  if [[ "$repos" == "null" ]]; then
    echo "[fatal] Project #$next_proj created but NOT linked to $REL_REPO_FULL"
    return 1
  fi

  local vis
  vis="$(rel_project_visibility_for_repo)"
  gh project edit "$next_proj" --owner "$REL_OWNER" --visibility "$vis" >/dev/null

  echo "$next_proj"
}

rel_projects_v2_json_for_owner() {
  emulate -L zsh
  set -euo pipefail

  local owner="$1"
  local repo_full="$2"

  local owner_type
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')" # User|Organization

  if [[ "$owner_type" == "Organization" ]]; then
    gh api graphql -f query='
      query($login:String!) {
        organization(login:$login) {
          projectsV2(first: 100) {
            nodes {
              number
              title
              closed
              repositories(first: 100) { nodes { nameWithOwner } }
            }
          }
        }
      }' -F login="$owner" \
    | jq -c '.data.organization.projectsV2.nodes'
  else
    gh api graphql -f query='
      query($login:String!) {
        user(login:$login) {
          projectsV2(first: 100) {
            nodes {
              number
              title
              closed
              repositories(first: 100) { nodes { nameWithOwner } }
            }
          }
        }
      }' -F login="$owner" \
    | jq -c '.data.user.projectsV2.nodes'
  fi
}