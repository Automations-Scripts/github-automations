rel_init() {
  set -euo pipefail

  local owner repo
  owner="$(gh repo view --json owner -q .owner.login)"
  repo="$(gh repo view --json name -q .name)"

  # 1) Não permitir dois projects abertos
  if gh project list --owner "$owner" --format json \
     | jq -e '.projects[] | select(.closed==false)' >/dev/null; then
    echo "❌ Já existe um Project (milestone) aberto para este owner."
    echo "   Use: todo"
    return 1
  fi

  # 2) Última tag do GitHub (fonte da verdade)
  local last
  last="$(gh api "repos/$owner/$repo/tags" --paginate -q '.[].name' \
          | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
          | sort -V | tail -n 1 || true)"
  last="${last:-v0.0.0}"

  # 3) Próxima versão (default: minor)
  local major minor patch next
  IFS=. read -r _ major minor patch <<<"${last#v}"
  next="v$major.$((minor+1)).0"

  echo "🆕 Criando milestone (Project): $next"

  # 4) Criar Project
  local proj
  proj="$(gh project create --owner "$owner" --title "$next" --format json | jq -r '.number')"

  echo "✅ Project criado: $next (#$proj)"

  # 5) Criar itens (se houver)
  local items_raw="${1:-}"
  if [ -n "$items_raw" ]; then
    echo "📋 Criando itens:"
    IFS='|' read -ra ITEMS <<<"$items_raw"

    for raw in "${ITEMS[@]}"; do
      local title
      title="$(echo "$raw" | xargs)"   # trim

      [ -z "$title" ] && continue

      # cria issue
      local issue_url issue_repo
      issue_url="$(
        gh issue create \
          --repo "$owner/$repo" \
          --title "$title" \
          --body "Planned for $next" \
          --assignee @me \
          --json url -q .url
      )"

      # adiciona ao project
      gh project item-add "$proj" --owner "$owner" --url "$issue_url" >/dev/null

      echo "  • $title"
    done
  else
    echo "ℹ️ Nenhum item informado (project criado vazio)"
  fi

  echo
  echo "👉 Próximo passo: todo"
}