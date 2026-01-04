todo() {
  set -uo pipefail

  local owner
  owner="$(gh repo view --json owner -q .owner.login)"

  local proj
  proj="$(
    gh project list --owner "$owner" --format json |
      jq -r '
        .projects
        | map(select(.closed == false))
        | map(select(.title | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
        | sort_by(.number)
        | .[0].number // empty
      '
  )"

  if [ -z "${proj:-}" ]; then
    echo "Nenhum Project aberto com título tipo vX.Y.Z encontrado para $owner."
    return 0
  fi

  local title
  title="$(gh project view "$proj" --owner "$owner" --format json | jq -r '.title')"

  echo "📌 Project aberto: $title (#$proj)"
  echo

  gh project item-list "$proj" --owner "$owner" --format json |
    jq -r '
      .items
      | if (length==0) then
          "   (sem itens)"
        else
          .[]
          | ("- [" + (.status // "No status") + "] " + (.title // .content.title // "Untitled"))
        end
    '
}