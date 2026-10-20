# Benchmark PT-BR (WER + latência)

## Comparação local de ditado Turbo — 20/10/2026

MacBook Pro M1 Pro, 16 GB. Três áudios sintéticos Luciana/PT-BR de 7,59,
13,79 e 7,90 segundos, com referências fixadas antes da medição, três
repetições por áudio/modelo após aquecimento (nove inferências por modelo).
O caminho medido é `TranscriptionManager.transcribe`, incluindo a finalização
do ditado, mas sem carga do modelo, captura do microfone ou colagem.

| Variante | Média por áudio | WER estrito | WER sem acento | RTF |
|---|---:|---:|---:|---:|
| `openai_whisper-large-v3_turbo` | 6,43 s | 7,0% | 5,6% | 0,660 |
| `openai_whisper-large-v3-v20240930_turbo` | 2,36 s | 7,0% | 7,0% | 0,242 |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | 1,22 s | 5,6% | 5,6% | 0,125 |

Compacto foi 5,26× mais rápido que a variante anterior nesta amostra, sem
aumento de WER sem acento; o export 2024 não comprimido foi 2,73× mais rápido.
WER também penaliza formatação correta de números (palavras versus algarismos).
Uma única voz sintética e três áudios não comprovam qualidade geral em PT-BR,
nomes, ruído, fala baixa, microfone real ou sessões longas.

Os dois novos exports foram obtidos de `argmaxinc/whisperkit-coreml`, revisão
`0f63a7800b00dd0226abd051b906c246e1907482`, com tamanho e hash de todos os
arquivos verificados antes de publicar a pasta: 1.638.464.446 bytes/24 arquivos
no export 2024 e 645.668.913 bytes/22 arquivos no Compacto. Ambos declaram
32 camadas de encoder e quatro de decoder. A variante antiga instalada
declara 32/32 e foi preservada; isso não estabelece corrupção do download.

A primeira preparação/compilação do Compacto levou 311,1 s; uma segunda
execução em outro processo carregou o cache em 3,7 s. Esses custos não entram
nas médias acima; atualizações de sistema/cache podem exigir nova compilação.
O export 2024 levou 26,7 s na preparação inicial.

Após aprovação explícita do usuário, Compacto foi selecionado no ditado.
A seleção separada das reuniões e todos os modelos anteriores foram mantidos.
Nenhum áudio privado ou serviço de nuvem foi usado neste benchmark.
Evidências locais: `/tmp/speaktype-turbo-comparison.md`,
`/tmp/speaktype-turbo-comparison.log`, `/tmp/speaktype-turbo-compact-cached.log`
e `/tmp/speaktype-turbo-fixture-manifest.json` (artefatos temporários).

## Comparação local de reuniões — 20/10/2026

No MacBook Pro M1 Pro de 16 GB, um áudio sintético Luciana/PT-BR de 7,59 s
passou pelo escritor/conversor real de reuniões e produziu um trecho:

| Modelo já instalado | Carga | Primeira transcrição | Média de 3 repetições aquecidas | WER sem acento (primeira) |
|---|---:|---:|---:|---:|
| `openai_whisper-large-v3_turbo` | 1,81 s | 11,87 s | 5,88 s | 0 |
| `freds0_distil-whisper-large-v3-ptbr` | 2,21 s | 4,74 s | 2,12 s | 0 |

Distil foi aproximadamente 2,8× mais rápido nas repetições desse trecho.
Esses tempos **não** incluem espera pela pausa, fila ao vivo, captura ou
encerramento da reunião; a carga é medida separadamente. Um único áudio
sintético sem erros não comprova qualidade geral, fala baixa ou reuniões longas.
O modelo PT-BR permanece experimental; não deve substituir silenciosamente
uma seleção explícita nem ser usado para outros idiomas.

Um segundo áudio sintético de 13,79 s, com nomes, números e termos em inglês,
foi dividido pelo escritor em duas partes. A primeira transcrição levou 17,73 s
no modelo atual e 6,75 s no Distil; ambos tiveram WER sem acento de 11,4%.
Isso reforça o ganho de velocidade nesse cenário, mas também mostra por que é
necessário revisar nomes, números e palavras nas divisões dos trechos.

Para repetir usando apenas um áudio de referência conhecido:

```bash
TEST_RUNNER_SPEAKTYPE_MEETING_AUDIO=/caminho/teste.aiff \
TEST_RUNNER_SPEAKTYPE_MEETING_REFERENCE='Transcrição exata do áudio de teste.' \
TEST_RUNNER_SPEAKTYPE_MEETING_REPORT=/tmp/meeting-benchmark.json \
TEST_RUNNER_SPEAKTYPE_MEETING_VARIANT=freds0_distil-whisper-large-v3-ptbr \
TEST_RUNNER_SPEAKTYPE_MEETING_BENCHMARK=1 \
xcodebuild test -project speaktype.xcodeproj -scheme speaktype \
  -configuration Debug -derivedDataPath build/local-derived \
  -destination 'platform=macOS' \
  -only-testing:speaktypeTests/MeetingTranscriptionIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

O relatório inclui carga, primeira inferência, três repetições, WER e quantidade
de partes. A referência padrão é a frase sintética de reunião usada no teste;
para outro áudio, informe sempre sua própria referência. Nenhum modelo é baixado.

## Benchmark de ditado

Mede, para cada modelo com suporte a português **já baixado** no app, a taxa de
erro de palavras (WER), o tempo de carga e o fator de tempo real (RTF) em um
conjunto de gravações suas. Nada é baixado pelo benchmark: modelos ausentes são
pulados.

## 1. Gravar os clipes (~30)

Grave no mesmo microfone e ambiente em que você dita no dia a dia (mono, 16 kHz
ou mais; `.wav` ou `.m4a`). Uma divisão que funciona bem:

- **~20 curtos (3–10 s)** — o uso típico de ditado: uma frase, uma mensagem.
- **~10 longos (30–90 s)** — um parágrafo, um e-mail, uma explicação.

Varie o conteúdo de propósito, porque é onde os modelos erram:

- **Nomes próprios**: pessoas, empresas, cidades ("A Fernanda da Totvs chega em
  Florianópolis na quinta").
- **Números**: datas, horários, valores, telefones, porcentagens ("R$ 1.250,00",
  "às 14h30", "dia 3 de março", "12%").
- **Perguntas** e exclamações, para avaliar entonação e pontuação.
- Termos técnicos/estrangeiros que você usa ("deploy", "pull request").
- Fala natural com hesitação, e alguns clipes ditados mais rápido.

Dica: o QuickTime (Arquivo › Nova Gravação de Áudio) exporta `.m4a`.

## 2. Estrutura dos arquivos

Uma pasta com pares de mesmo nome — áudio + transcrição de referência:

```
~/bench-ptbr/
  curto-01-reuniao.m4a
  curto-01-reuniao.txt
  curto-02-pergunta.wav
  curto-02-pergunta.txt
  longo-01-email.m4a
  longo-01-email.txt
  ...
```

O `.txt` (UTF-8) deve conter **exatamente o que foi dito**, com acentos. Caixa e
pontuação são ignoradas no cálculo. Como o benchmark mede a saída final do app
(depois do dicionário e da formatação PT-BR), escreva números como você quer
que o app os escreva ("14h30", "12%", "3 de março") — divergências como "doze
por cento" × "12%" contam como erro.
Áudios sem `.txt` correspondente são ignorados.

## 3. Rodar

```bash
# todos os modelos PT baixados
scripts/benchmark-ptbr.sh ~/bench-ptbr

# só alguns modelos (variantes separadas por vírgula)
scripts/benchmark-ptbr.sh ~/bench-ptbr nemotron-multilingual-pt-br-560ms,openai_whisper-large-v3_turbo
```

Para medir estabilidade, prefixe o comando com
`TEST_RUNNER_SPEAKTYPE_BENCH_REPETITIONS=3`. Cada áudio será processado três vezes
por modelo após o aquecimento. O limite é cinco repetições; o padrão continua um.

O script executa apenas `PTBRBenchmarkTests` via `xcodebuild test`, repassando
as variáveis `SPEAKTYPE_BENCH_DIR` / `SPEAKTYPE_BENCH_MODELS` (prefixo
`TEST_RUNNER_`). O resultado aparece no terminal e é salvo em
`build/benchmark-ptbr-<data-hora>.md`; o log completo do build fica em
`build/benchmark-ptbr-xcodebuild.log`. Sem `SPEAKTYPE_BENCH_DIR`, o teste é
pulado, então ele não afeta `make test`.

## 4. Como ler o resultado

A tabela principal tem uma linha por modelo, ordenada pelo menor WER:

| Coluna | Significado |
|---|---|
| **Carga (s)** | Tempo de `loadModel` na primeira carga do processo (inclui compilação Core ML; na primeira vez após o download pode ser bem maior). |
| **WER** | Erros (substituições + omissões + inserções) ÷ palavras da referência, somando todos os clipes. Acentos contam: "voce" ≠ "você". |
| **WER s/ acento** | Mesmo cálculo ignorando diacríticos. Diferença grande entre as duas colunas = o modelo acerta a palavra mas erra a acentuação. |
| **RTF** | Tempo de processamento ÷ duração do áudio. 0,10 = 1 minuto de fala transcrito em 6 s. Abaixo de 1 é mais rápido que tempo real. |
| **RTF curtos / longos** | RTF separado para clipes < 15 s e ≥ 15 s. Em clipes curtos o custo fixo por chamada pesa mais. |

Referência prática: WER abaixo de ~10% costuma ser bom para ditado; acima de
~20% exige muita correção manual. Para latência percebida em ditado curto,
multiplique o RTF curto pela duração típica da sua fala (ex.: RTF 0,15 × 6 s ≈
0,9 s de espera após soltar a tecla).

Abaixo da tabela há uma seção por modelo com o resultado de cada clipe e a
transcrição gerada — use-a para ver *que tipo* de erro acontece (nomes, números,
pontuação de perguntas).

Observações:

- Antes de medir, cada modelo faz uma transcrição de aquecimento (não contada)
  no clipe mais curto.
- Os modelos Nemotron são medidos pelo caminho em lote (arquivo inteiro), que
  usa o mesmo decodificador do ditado ao vivo; o RTF ao vivo é semelhante, mas a
  latência ao vivo também depende do tamanho do bloco (560/1120/2240 ms).
- Feche apps pesados durante a execução; o RTF varia com carga de CPU/ANE.
