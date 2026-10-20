# SpeakType

<div align="center">

![SpeakType Icon](speaktype/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

**Fast, Offline Voice-to-Text for macOS**

![SpeakType app screenshot](image.png)
[![Fork](https://img.shields.io/badge/Fork-ygormteus%2Fspeaktype-blueviolet?logo=github)](https://github.com/ygormteus/speaktype)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0+-blue?logo=apple)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-red)](LICENSE)

*Press a hotkey, speak, and instantly paste text anywhere on your Mac.*

</div>

---

## What is SpeakType?

SpeakType is a **privacy-first voice dictation and meeting tool** for macOS. Dictation and meeting speech transcription run locally using Whisper via [WhisperKit](https://github.com/argmaxinc/WhisperKit). Meeting summaries can use available Apple Intelligence locally or an optional OpenAI API connection with confirmation before sending transcript text.

- **Privacy First** - Local dictation and transcription; cloud summaries are optional and require explicit confirmation
- **Lightning Fast** - Optimized for Apple Silicon
- **Works Everywhere** - Any app, any text field
- **Open Source** - Audit every line of code yourself

---

## Installation

### Requirements

- macOS 14.0+ (Sonoma or newer)
- Apple Silicon (M1+) recommended
- 2GB available storage (for AI models)

### Download

**[Open this fork](https://github.com/ygormteus/speaktype)**

1. Download `SpeakType.dmg`
2. Drag **SpeakType** to **Applications**
3. Grant Microphone + Accessibility + Documents Folder permissions
4. Download an AI model from Settings → AI Models

Press `fn` to start dictating.

### Build from Source

```bash
git clone https://github.com/ygormteus/speaktype.git
cd speaktype
make run-local
```

`make run-local` mantém o aplicativo de desenvolvimento em um caminho fixo,
evitando que o macOS peça as permissões novamente a cada build. Veja o
[guia de distribuição e testes](docs/DISTRIBUTION.md) para o fluxo assinado.

---

## Usage

### Reuniões presenciais e online

Abra **Reuniões → Nova reunião**, escolha título, idioma e origem. O modo presencial
usa o microfone padrão do sistema; o online adiciona o áudio do sistema via
ScreenCaptureKit. Permita microfone e, para reuniões online, gravação de tela/áudio
do sistema em **Ajustes do Sistema → Privacidade e Segurança**. Informe os participantes
sobre a gravação. Use fones para reduzir eco e duplicação; as fontes “microfone” e
“sistema” não identificam pessoas.

A criação mostra **Modelo de transcrição**, separado do modelo do ditado. Escolha
**Rápido PT-BR (experimental) · Distil-Whisper PT-BR** para priorizar velocidade
em português ou **Maior fidelidade · Whisper Large v3 Turbo**. Só aparecem modelos
compatíveis já baixados; instale os ausentes em **Modelos de IA**. A escolha é
lembrada para novas reuniões, sem alterar o ditado, e o modelo efetivo aparece no
detalhe. Ao mudar o idioma, opções incompatíveis são retiradas. Reprocessar uma
reunião usa o modelo salvo nela, não a preferência de novas reuniões.

A captura é iniciada e encerrada manualmente. Escolha **Presencial · Só minha voz**
para gravar apenas o microfone. A tela mostra o nível do áudio e separa as abas
**Transcrição** e **Resumo**. Os trechos são enviados ao modelo local após pausas
(entre 3 e 8 segundos), em vez de esperar blocos fixos de 15 segundos. O primeiro
resultado ainda pode levar alguns segundos enquanto o modelo é preparado.
O texto mostrado durante a captura é provisório; segmentos pendentes
continuam sendo transcritos após o encerramento. O modelo multilíngue fica fixo até
terminar a fila. Reuniões não colam texto no app em foco.

O áudio fica em segmentos fechados em
`~/Library/Application Support/SpeakType/Meetings/<UUID>/`, com manifesto e transcrição.
Depois de uma interrupção, reabra o app e use **Tentar transcrever o áudio salvo novamente**.
Isso processa arquivos salvos e não retoma a gravação. Falhas de fontes e lacunas
ficam visíveis; áudio nunca é removido automaticamente. **Excluir reunião** pede
confirmação e remove seus arquivos locais. No detalhe, **Ouvir o áudio salvo** permite
conferir a captura; o menu **… → Transcrever o áudio salvo novamente** refaz também
os trechos já concluídos e limpa o resumo anterior, sem remover a gravação.
A reprodução é bloqueada durante gravações para evitar que entre no microfone.
O detalhe exporta texto e resumo em Markdown.

Na aba **Resumo**, selecione **Neste Mac** e **Gerar resumo**. Isso depende de macOS 26, Apple Intelligence habilitado, modelo
disponível e suporte ao idioma. Quando indisponível, gravação/transcrição local
continuam funcionando. **Nuvem · OpenAI** usa a [OpenAI Responses API](https://developers.openai.com/api/docs/guides/responses)
com modelo configurável (`gpt-4.1-mini` inicialmente). Configure a chave opcional em
**Configurações → IA para reuniões**; ela fica no Keychain, separada da licença.
Somente após confirmar cada envio, o texto da transcrição sai do Mac; áudio não é
enviado. Aplicam-se custos da API e políticas de retenção do provedor. A opção
`store: false` não representa promessa de retenção zero. Falhas locais não acionam a nuvem.

Resumos incluem visão geral, assuntos, decisões, pendências e tarefas, com referências
à transcrição. Responsáveis e prazos só devem aparecer quando citados. Confira o
resultado antes de usá-lo: referências válidas não provam fidelidade semântica.
O resumo local usa referências numéricas curtas, resolvidas pelo app para os trechos
originais. Campos ausentes e citações repetidas são normalizados; referências
desconhecidas ou responsáveis/prazos sem apoio na fonte continuam sendo rejeitados.
Capturas reais longas ainda exigem avaliação de memória, latência e qualidade em PT-BR.

### Ditado

1. Press hotkey (`fn` by default)
2. Speak your text
3. Release hotkey
4. Text appears!

For hands-free dictation, select **Fn** and **Hold to record** in Settings, then enable
**Double-tap Fn for hands-free recording**. Tap Fn twice quickly to keep recording;
press Fn again to transcribe and paste, or Esc to cancel. Holding and releasing Fn
still works. This option is off by default and does not change Toggle mode.

If dictation only copies text instead of pasting, enable SpeakType under **System
Settings → Privacy & Security → Accessibility**. The app now explains this after
dictation when permission is missing. After replacing a locally built app, you may
need to remove its old entry and add `/Applications/speaktype.app` again. Your
transcript remains on the clipboard while permission is unavailable.

**Tips:**
- Speak naturally - Whisper handles accents well
- Say punctuation: "comma", "period", "question mark"
- Best results with 3-10 second clips

---

## Development

```bash
make build          # Build debug
make run            # Run app
make clean          # Clean build
make test           # Run tests
make dmg            # Create DMG installer
```

### Current Issues

⚠️ When loading a model for the first time / switching to another model, there is a startup delay of 30-60 seconds. 

So the first transcription will appear ultra slow, but it will go back to instantaneous dictation right after it's warmed up. 

### Project Structure

```
speaktype/
├── App/           # Entry point
├── Views/         # SwiftUI interface
├── Models/        # Data models
├── Services/      # Core functionality
├── Controllers/   # Window management
└── Resources/     # Assets & config
```

### Tech Stack

- **Swift 5.9+** / SwiftUI + AppKit
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** - Local Whisper inference
- **[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)** - Global hotkeys
- **AVFoundation** - Audio capture

---

## Contributing

1. Fork & clone
2. Create a branch: `git checkout -b feature/my-feature`
3. Make changes and run `make lint`
4. Submit a PR

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Credits

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax
- [OpenAI Whisper](https://github.com/openai/whisper)

---

<div align="center">

**Made with ❤️ for developers**

*Privacy-first • Open Source *

</div>
