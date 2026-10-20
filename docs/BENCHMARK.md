# Benchmark PT-BR (WER + latência)

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
