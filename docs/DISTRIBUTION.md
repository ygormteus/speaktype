# Distribuição e testes locais

## Desenvolvimento na mesma máquina

Use `make run-local`. Ele cria sempre o aplicativo em
`build/local-derived/Build/Products/Debug/speaktype.app`, sem assinatura.
Como o caminho e a identidade do aplicativo permanecem estáveis, macOS não
pede novamente as permissões de Microfone e Acessibilidade a cada compilação.

Depois de abrir o aplicativo, confirme em **Ajustes > Permissões** que as duas
permissões estão ativas. Para validar a colagem automática, deixe um campo de
texto aberto em outro aplicativo, inicie o ditado pelo atalho e solte-o.

## Release para outras máquinas

O fluxo já existente é `make create-release VERSION=x.y.z`. Ele exige uma
árvore Git limpa, atualiza a versão, assina o aplicativo com Developer ID,
gera o DMG, envia-o para notarização da Apple e valida a assinatura. Só depois
de um resultado aceito deve-se executar `make deploy-release x.y.z`, que envia
a tag e publica o DMG no GitHub Releases.

As credenciais de notarização ficam apenas no Chaveiro do macOS, no perfil
configurado para `notarytool`; não devem ser colocadas em arquivos do projeto,
arquivos `.env`, ou no Git. Antes de publicar, valide também o DMG em uma conta
ou máquina que não tenha executado a compilação, para confirmar Gatekeeper,
Microfone e Acessibilidade desde uma instalação limpa.

## Checklist de saída

1. Execute `make test` e `make build-local`.
2. Teste uma transcrição curta em português e em inglês.
3. Teste colagem automática, revisão antes de colar e o modo "Apenas copiar".
4. Confirme que não há arquivos `.env`, `.claude` ou `.codex` no diff.
5. Gere e valide o DMG assinado e notarizado antes do envio ao GitHub.
