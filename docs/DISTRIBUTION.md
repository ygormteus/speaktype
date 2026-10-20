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

### Beta manual para Apple Silicon — 20/10/2026

O pré-lançamento [v1.3.0-beta.20261020](https://github.com/ygormteus/speaktype/releases/tag/v1.3.0-beta.20261020)
distribui `SpeakType-1.3.0-4c09df5-AppleSilicon-beta.dmg`, o checksum SHA-256
e instruções de instalação. O binário Release arm64 foi compilado originalmente
a partir de `4c09df5368ca82026ec3a5dd2804bbacdce15a91`. Após a correção apenas
da coautoria no histórico, o commit equivalente é
`d0073125fc05cbd60ac1a49719f907d796b8586b`, com árvore de arquivos idêntica.
O nome e o checksum do instalador permanecem inalterados. O pacote atende
Macs Apple Silicon, incluindo M3. Os arquivos binários ficam nos anexos do GitHub Releases,
não no histórico Git; `dist/` continua ignorado.

**É um pacote de teste com assinatura local ad hoc, sem Developer ID e sem
notarização Apple.** Isso não autentica a identidade do desenvolvedor e não
equivale ao fluxo oficial descrito abaixo. A instalação limpa em outro Mac
ainda precisa ser validada. O DMG e a assinatura local do aplicativo foram
verificados antes do envio.

Abra o DMG, arraste `speaktype.app` para Aplicativos e abra-o por essa pasta.
Autorize Microfone e Acessibilidade; reuniões online também podem exigir
permissão de captura de áudio do sistema. Baixe e selecione o modelo
**Whisper Large v3 Turbo (Compacto)** na máquina de destino. Modelos, histórico,
gravações, preferências e chaves pessoais não acompanham o pacote.

Se o macOS bloquear a abertura, confirme a procedência antes de usar
**Ajustes do Sistema > Privacidade e Segurança > Abrir Mesmo Assim**, conforme
a [orientação da Apple](https://support.apple.com/pt-br/102445). Não desative
globalmente o Gatekeeper. Um Mac gerenciado pode exigir aprovação do administrador.

O aplicativo declara macOS 14 como mínimo, mas esta compilação foi gerada no
macOS 27.2; versões anteriores não foram validadas neste pacote. Resumo local
depende de macOS 26 ou posterior e Apple Intelligence disponível e habilitado.
O rodapé de atribuição aparece no Release; a data/hora de compilação é exibida
somente em Debug.

### Release assinada e notarizada

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
5. Para uma release oficial, gere e valide o DMG assinado e notarizado antes
   do envio ao GitHub. Betas manuais devem ser marcadas como pré-lançamento,
   com o aviso explícito de ausência de notarização e checksum do instalador.
