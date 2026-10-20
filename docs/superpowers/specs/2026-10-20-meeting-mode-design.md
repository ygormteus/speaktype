# Modo Reunião — especificação para revisão

Status: especificação e plano aprovados pelo usuário em 2026-10-20; implementação concluída, validação manual de captura real e reuniões longas pendente.

## Objetivo e escopo acordado

Adicionar ao SpeakType acompanhamento manual de reuniões presenciais e online,
com transcrição em português e resumos posteriores. Manter processamento local
e oferecer IA na nuvem como escolha explícita. Preservar o ditado, a colagem
automática corrigida e a opção de ativação com dois toques em Fn.

O modo Reunião é independente do perfil de formatação “Reunião” do ditado.
Uma reunião nunca cola transcrições automaticamente no aplicativo em foco.

## Abordagens e recomendação

- Reaproveitar o controlador do ditado: menos código inicialmente, mas mistura
  gravação longa, histórico e colagem automática; não recomendado.
- Criar um subsistema de reuniões e compartilhar somente interfaces de áudio e
  transcrição: recomendado por permitir persistência e recuperação próprias.
- Depender integralmente de um serviço remoto: simplifica parte do processamento,
  mas não atende à opção local solicitada.

## Experiência proposta

Nova área “Reuniões”, com lista local e ação “Nova reunião”. Antes de iniciar,
selecionar título, idioma e origem: presencial (microfone) ou online
(microfone + áudio do sistema). Exibir as fontes ativas, duração, estado da
captura e aviso para informar os participantes sobre a gravação.

A primeira versão oferece iniciar e encerrar manualmente. Detecção automática
de chamadas, pausa e retomada voluntárias ficam fora desta primeira entrega.
Durante a captura, mostrar transcrição parcial identificada como provisória.
Ao encerrar, finalizar segmentos pendentes e abrir o detalhe da reunião.

O detalhe contém transcrição com referências temporais, estado do processamento
e ação para gerar resumo. O usuário escolhe “Local” ou “Nuvem” nessa ação.
Exportação inicial em Markdown inclui a transcrição e o resumo disponível.

## Captura e transcrição

Usar um coordenador próprio de sessão, com identificador estável. Presencial usa
microfone; online usa um adaptador ScreenCaptureKit para áudio do sistema e uma
fonte de microfone. Validar disponibilidade e permissões antes de gravar.
Excluir o próprio áudio do SpeakType quando a API disponível permitir.

Normalizar formatos e registrar tempos relativos ao mesmo relógio de sessão.
Manter canais de origem separados; “microfone” e “sistema” não identificam pessoas.
A captura com alto-falantes pode conter eco e duplicações; orientar o uso de fones
e não prometer cancelamento de eco na primeira versão.

Transcrever localmente com modelo multilíngue compatível com português,
reaproveitando o roteamento existente onde seguro. Não mudar o modelo durante
uma sessão. Transcrição em nuvem fica fora da primeira versão: a opção de nuvem
inicial aplica-se aos resumos, sem upload de áudio.

Não reutilizar sem adaptação a sessão incremental de ditado: ela remove arquivos
processados e prevê fallback para o áudio completo. Reuniões precisam de fila
durável de segmentos, limites de concorrência e processamento com memória
limitada, sem depender de carregar toda a gravação em RAM.

Se o processamento ficar para trás, preservar segmentos em disco e mostrar a
fila pendente. Falha de escrita ou espaço insuficiente encerra a captura com
erro visível. Perda de uma fonte online nunca deve ser apresentada como captura
completa: registrar a lacuna e permitir finalizar o material já salvo.

## Persistência e recuperação

Criar armazenamento próprio em Application Support, separado do histórico de
ditado. Salvar manifesto versionado atomicamente e segmentos de áudio fechados
ao longo da sessão. Persistir transcrição por segmento, origem, intervalo,
estado e erros; somente eliminar áudio por ação explícita do usuário.

Estados propostos: preparando, gravando, finalizando, transcrevendo, concluída,
interrompida e falhou. Resumo tem estado separado: ausente, gerando, pronto ou
falhou. Falha de resumo não invalida a transcrição.

Após encerramento inesperado, oferecer recuperação dos segmentos íntegros e
reprocessamento pendente. Não retomar gravação automaticamente. Exclusão de
reunião exige confirmação e remove seus arquivos locais associados.

## Resumos locais e na nuvem

Definir uma interface de resumo independente do formatador de pontuação, que
atualmente preserva palavras e proíbe resumir. Resultado: visão geral, assuntos,
decisões, pendências e tarefas. Responsáveis e prazos só aparecem quando citados;
ausências ficam explícitas. Cada item referencia segmentos da transcrição.

Local: avaliar FoundationModels com verificações de versão, disponibilidade e
suporte efetivo ao idioma. O projeto mantém macOS 14 como mínimo; logo, esse
backend não pode ser obrigatório. Quando indisponível, manter gravação e
transcrição locais e explicar a indisponibilidade do resumo, sem trocar para
nuvem. Um modelo local adicional distribuído pelo app exige decisão posterior
de tamanho, licença e desempenho; não será baixado silenciosamente.

Nuvem: proposta inicial de um provedor configurável com credencial no Keychain,
isolada da licença do app. Antes de cada envio, indicar provedor e que o conteúdo
da transcrição sairá do Mac; enviar somente após confirmação. Nunca colocar
chaves, áudio ou conteúdo da reunião em logs. Não prometer retenção zero pelo
provedor. Provedor inicial e modelos serão fechados antes da implementação do
adaptador remoto; nenhuma chave é necessária nesta etapa de projeto.

Para reuniões longas, resumir blocos e depois consolidar com referências estáveis,
limites de contexto e cancelamento. Tratar transcrição como dados não confiáveis,
não como instruções. Validar a estrutura e referências retornadas; referências
válidas não garantem fidelidade semântica, que requer avaliação em português.

## Entregas propostas e critérios de aceite

1. Base local: modelos, armazenamento, recuperação e testes de falhas.
2. Captura presencial e transcrição durável, sem ações de clipboard.
3. Captura online e diagnóstico de permissões, fontes e lacunas.
4. Resumo local disponível por capacidade e resumo remoto opt-in.
5. Interface PT-BR, exportação, validação e atualização reversível no Mac.

Testar persistência e migração, fila atrasada, disco indisponível, recuperação,
ordem e tempos dos segmentos, erros de fontes, cancelamento de resumos e ausência
de envio remoto sem consentimento. Rodar testes existentes para evitar regressões
no ditado, Fn e clipboard.

Validação manual no Mac inclui reunião presencial, chamada com fones, negação de
permissões e interrupção da captura. Comparar áudio conhecido com transcrição e
resumo em português. Medir uso de memória e atraso numa sessão de pelo menos
60 minutos; não afirmar suporte a reuniões longas apenas por testes unitários.

## Fora de escopo inicial

Identificação automática de falantes, integração de calendários, bots que entram
em chamadas, sincronização de reuniões, perguntas sobre o acervo e gravação
oculta. Não há publicação, compartilhamento nem envio de dados por padrão.

## Aprovação

O usuário aprovou esta especificação, o plano e a execução nativa em 2026-10-20.
Os resultados de validação estão no plano de implementação.
