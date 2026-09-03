# Localização bilíngue: português brasileiro e inglês

## Objetivo

Oferecer toda a interface do SpeakType em português brasileiro e inglês, usando
o idioma do macOS por padrão e permitindo que cada pessoa escolha um idioma
explicitamente em Ajustes.

## Arquitetura

- Adotar `Localizable.xcstrings` como fonte única dos textos da interface.
- Usar chaves semânticas e comentários de contexto; nunca usar o texto em inglês
  como identificador de negócio.
- Cobrir telas SwiftUI, menu de barra, onboarding, alertas, estados de gravação,
  permissões, histórico, dicionário, modelos e atualização.
- Preservar nomes próprios e técnicos: SpeakType, Whisper, Parakeet, macOS,
  OpenAI, NVIDIA e atalhos de teclado.

## Preferência de idioma

Uma preferência persistida terá três opções: seguir o sistema, português
brasileiro e inglês. `seguir o sistema` será o padrão. A raiz da aplicação
aplicará o locale escolhido ao ambiente SwiftUI; a alteração deverá atualizar
as janelas e popovers ativos sem reiniciar o aplicativo.

## Experiência e erros

O seletor ficará em Ajustes, em uma seção Geral. Rótulos, descrições, mensagens
de acesso negado e alertas usarão o locale ativo. Mensagens de erro vindas de
bibliotecas externas poderão permanecer no idioma original quando não houver
uma representação controlada pelo app.

## Validação

- Testar a resolução de `seguir o sistema`, português e inglês.
- Testar a persistência da preferência.
- Compilar o alvo macOS e executar a suíte de testes disponível.
- Fazer revisão visual do onboarding, menu de barra e Ajustes em ambos idiomas.

## Fora de escopo

- Tradução do texto transcrito pelo usuário.
- Troca automática de modelo por idioma.
- Tradução de conteúdo de terceiros ou de nomes técnicos.
