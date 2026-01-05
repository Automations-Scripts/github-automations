rel_wipe_project() {
  emulate -L zsh
  set -euo pipefail

  # Repo atual
  local repo_full owner repo owner_type
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"
  owner="${repo_full%%/*}"
  repo="${repo_full##*/}"

  echo
  echo "🔎 Repositório alvo:"
  echo "   $repo_full"
  echo

  # Tipo do owner (User | Organization)
  owner_type="$(gh api "repos/$repo_full" -q '.owner.type')"
  echo "Owner type: $owner_type"
  echo

  local raw projects

  if [[ "$owner_type" == "Organization" ]]; then
    raw="$(
      gh api graphql -f query='
        query($login:String!) {
          organization(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                repositories(first: 100) {
                  nodes { nameWithOwner }
                }
              }
            }
          }
        }' -F login="$owner"
    )"

    projects="$(
      echo "$raw" | jq -c --arg REPO "$repo_full" '
        .data.organization.projectsV2.nodes[]
        | select(.repositories.nodes[].nameWithOwner? == $REPO)
      '
    )"
  else
    raw="$(
      gh api graphql -f query='
        query($login:String!) {
          user(login:$login) {
            projectsV2(first: 100) {
              nodes {
                number
                title
                repositories(first: 100) {
                  nodes { nameWithOwner }
                }
              }
            }
          }
        }' -F login="$owner"
    )"

    projects="$(
      echo "$raw" | jq -c --arg REPO "$repo_full" '
        .data.user.projectsV2.nodes[]
        | select(.repositories.nodes[].nameWithOwner? == $REPO)
      '
    )"
  fi

  if [[ -z "${projects:-}" ]]; then
    echo "✅ Nenhum Project associado a este repositório."
    return 0
  fi

  echo "📋 Projects associados a $repo_full:"
  echo
    echo "$projects" | jq -r '
    "• #\(.number)\t\(.title)\t(repos: \((.repositories.nodes | map(.nameWithOwner) | join(","))))"
    '
  echo

  echo "⚠️  ATENÇÃO: estes Projects serão APAGADOS DEFINITIVAMENTE."
  echo -n "Digite exatamente DELETE para confirmar: "
  local confirm
  read -r confirm

  if [[ "$confirm" != "DELETE" ]]; then
    echo "❌ Cancelado. Nenhum project foi removido."
    return 1
  fi

  echo
  echo "🔥 Apagando Projects..."

  echo "$projects" | jq -r '.number' | while read -r n; do
    echo "  🗑️  Deletando project #$n"
    gh project delete "$n" --owner "$owner"
  done

  echo
  echo "✅ Limpeza concluída."
}

rel_wipe_releases() {
  emulate -L zsh
  set -euo pipefail

  local repo_full
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"

  echo
  echo "🔎 Repo: $repo_full"
  echo "📦 Listando releases..."
  echo

  local rels
  rels="$(gh release list --repo "$repo_full" --limit 1000 --json tagName,name,createdAt \
    | jq -c '.[]')"

  if [[ -z "${rels:-}" ]]; then
    echo "✅ Nenhuma release encontrada."
    return 0
  fi

  echo "📋 Releases encontradas:"
  echo "$rels" | jq -r '"• \(.tagName)\t\(.name // "-")\t\(.createdAt)"'
  echo

  echo -n "⚠️  Digite DELETE-RELEASES para apagar TODAS: "
  local confirm
  read -r confirm
  [[ "$confirm" == "DELETE-RELEASES" ]] || { echo "❌ Cancelado."; return 1; }

  echo
  echo "🔥 Apagando releases..."
  echo "$rels" | jq -r '.tagName' | while read -r tag; do
    [[ -z "$tag" ]] && continue
    echo "  🗑️  release $tag"
    gh release delete "$tag" --repo "$repo_full" -y
  done

  echo "✅ Releases apagadas."
}

rel_wipe_tags() {
  emulate -L zsh
  set -euo pipefail

  local repo_full
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"

  echo
  echo "🔎 Repo: $repo_full"
  echo "🏷️  Listando tags remotas..."
  echo

  local tags
  tags="$(gh api "repos/$repo_full/git/matching-refs/tags" --paginate \
    | jq -r '.[].ref | sub("^refs/tags/";"")')"

  if [[ -z "${tags:-}" ]]; then
    echo "✅ Nenhuma tag encontrada."
    return 0
  fi

  echo "📋 Tags encontradas:"
  echo "$tags" | sed 's/^/• /'
  echo

  echo -n "⚠️  Digite DELETE-TAGS para apagar TODAS: "
  local confirm
  read -r confirm
  [[ "$confirm" == "DELETE-TAGS" ]] || { echo "❌ Cancelado."; return 1; }

  echo
  echo "🔥 Apagando tags..."
  echo "$tags" | while read -r t; do
    [[ -z "$t" ]] && continue
    echo "  🗑️  tag $t"
    gh api -X DELETE "repos/$repo_full/git/refs/tags/$t" >/dev/null
  done

  echo "✅ Tags apagadas."
}

rel_wipe_all() {
  emulate -L zsh
  set -euo pipefail

  local repo_full
  repo_full="$(gh repo view --json owner,name -q '.owner.login + "/" + .name')"

  echo
  echo "☢️  WIPE TOTAL (releases + tags)"
  echo "Repo: $repo_full"
  echo

  echo -n "Digite exatamente NUKE para continuar: "
  local c
  read -r c
  [[ "$c" == "NUKE" ]] || { echo "❌ Cancelado."; return 1; }

  rel_wipe_releases
  rel_wipe_tags
}