# NOVA HOSPITAL ERP — Ordens de Trabalho

**Projecto:** NOVA HOSPITAL ERP  
**Ambiente:** Supabase de teste / Vercel  
**Organização técnica:** NOVA CLÍNICA — unidade piloto  
**Entidade emissora simulada:** IVATAXI – Prestação de Serviços (SU), LDA  
**NIF de teste indicado pelo utilizador:** 5001316257  
**Moeda / fuso:** AOA / Africa-Luanda

> Este plano é de desenvolvimento e homologação interna. Dados, preços e operações marcados como TESTE são fictícios. Não usar documentos produzidos neste ambiente como documentos fiscais reais. A validação oficial AGT depende de requisitos, credenciais e aprovação que não foram fornecidos nem simulados.

## Regras de execução

1. Não reiniciar nem substituir a arquitectura existente.
2. Cada OT deve identificar âmbito, dependências, entregáveis, testes e critérios de aceitação.
3. Dados simulados devem ser identificados e registados em `audit.test_data_registry`.
4. A limpeza futura deve actuar exclusivamente sobre IDs registados num lote de teste, com pré-visualização e confirmação explícita. Não apagar dados históricos ou não registados.
5. Não marcar integração, certificação, assinatura, comunicação AGT ou homologação oficial como concluída sem evidência real.
6. Nenhum preço simulado constitui tabela comercial ou tarifário aprovado.

## Registo Hospitalar do Paciente (NRH) — transversal\n\n**Estado:** Implementado na base de dados e interface; validação transaccional da API concluída.\n\n- Todo o novo registo em `patient.records`, independentemente do módulo de origem, recebe um NRH automático no formato `NRH-AAAA-000001`, sequencial por instituição e ano.\n- A geração é transaccional e centralizada num trigger da base de dados; não depende do browser nem do módulo que criou o paciente.\n- O NRH é imutável após a criação. O identificador técnico `medical_id` permanece separado e não deve ser apresentado como número de processo hospitalar.\n- O número é devolvido pelos fluxos de cadastro central e recepção sem marcação, e apresentado nos ecrãs de cadastro, pesquisa, recepção, internamento e diagnóstico.\n- Os registos históricos mantêm os números existentes; não foram renumerados para evitar quebrar documentos e referências já emitidos.\n- Teste transaccional confirmou o formato e a devolução do NRH pela API; a transacção foi revertida, sem paciente de teste persistido.\n\n## OT-001 — Fundação institucional, emissor de teste e catálogo hospitalar

**Estado:** EM EXECUÇÃO — base de dados e dados de demonstração preparados; validação ponta-a-ponta pendente.  
**Prioridade:** Crítica.

### Âmbito
- Configurar IVATAXI – Prestação de Serviços (SU), LDA / NIF 5001316257 apenas como emissor de teste.
- Manter o perfil da instituição hospitalar separado do perfil fiscal do emissor.
- Preparar lote de dados de teste e registo individual de cada linha criada.
- Preencher catálogo demonstrativo de serviços, classificações fiscais, departamentos de diagnóstico e infraestrutura de internamento.
- Preparar pré-visualização segura da limpeza de um lote, sem executar eliminação.

### Implementado
- Perfil fiscal de teste em ambiente de homologação; sem credenciais, assinatura, comunicação ou validação AGT.
- Configuração documental identificada como emissor simulado; facturação fiscal electrónica e SAF-T mantidos desactivados.
- Lote `TEST-NOVA-ERP-2026-001`.
- 9 serviços com preços ilustrativos; 8 classificados provisoriamente como serviços médico-sanitários M22 e 1 classificação pendente.
- 4 enfermarias, 5 quartos e 14 camas simuladas.
- 5 itens de catálogo de laboratório/imagiologia.
- 2 pacientes fictícios, 1 episódio clínico e 2 pedidos diagnósticos simulados.
- 42 registos individualmente inscritos no registo de dados de teste.
- Função `audit.preview_test_data_cleanup(uuid)`: apenas pré-visualiza; não elimina dados.

### Testes e aceitação pendentes
- Confirmar no ecrã institucional a separação entre entidade hospitalar e emissor de teste.
- Testar consulta, selecção de serviço, cotação no servidor e criação de factura em rascunho.
- Confirmar que documentos de teste não podem ser finalizados como documentos fiscais oficiais.
- Confirmar que o painel de limpeza apresenta apenas os IDs registados no lote.
- Validar a classificação M22 serviço a serviço com o enquadramento fiscal real antes de qualquer produção.

## OT-002 — Urgência e emergência

**Estado:** EM EXECUÇÃO — entrada de urgência e fila testadas; triagem clínica aguarda profissional habilitado activo.  
**Prioridade:** Crítica.

### Âmbito
- Admissão urgente, identificação e triagem.
- Classificação de prioridade e tempos de atendimento.
- Episódio clínico de urgência, observações, evolução e prescrições.
- Pedidos de laboratório/imagiologia associados ao episódio.
- Decisão clínica, transferência, internamento, alta ou óbito.
- Registo cronológico e auditoria de cada transição.

### Critérios de aceitação
- Não permitir caso de urgência sem paciente, visita de recepção, triagem e episódio clínico válidos.
- Alertas para prioridades críticas e atrasos.
- Encaminhamento para internamento sem duplicar o paciente nem o episódio.
- Testes com pacientes exclusivamente fictícios.

### Implementado / validado
- Corrigida a estrutura de recepção para permitir entradas sem marcação, mantendo a ligação à marcação opcional.
- Reforçadas permissões de leitura/gestão da fila para o proprietário institucional e permissão de triagem para o perfil de médico.
- Entrada de urgência simulada criada e visível na fila, com estado de triagem pendente.
- A fila confirma `can_assess_triage=false` para utilizador sem perfil clínico habilitado; o sistema não permite abrir episódio de emergência sem triagem.

### Bloqueio para aceitação
- Associar um utilizador real de teste a perfil de enfermeiro ou médico activo, com departamento e unidade correctos. Não foi criado um profissional fictício com identidade de outro utilizador.
- Depois, testar classificação de risco, sinais vitais, abertura do episódio e transições até alta/transferência.

## OT-003 — Laboratório LIS e Imagiologia RIS/PACS

**Estado:** EM EXECUÇÃO — base de dados LIS/RIS preparada; interface operacional, regras de validação clínica e testes ponta-a-ponta pendentes.  
**Prioridade:** Alta.

### Âmbito
- Catálogo, requisição, colheita, recepção de amostras, processamento e validação.
- Resultados estruturados, intervalos de referência e valores críticos.
- Agenda de exames, execução, laudo e anexação de imagens.
- Histórico de alterações e validação por profissional autorizado.
- Rastreio de amostras por código, estado, recolha, recepção e rejeição.
- Registo de estudos de imagem, modalidade, região anatómica, accession number, relatório e referência segura ao armazenamento DICOM.

### Implementado nesta fase
- Criada `clinical.diagnostic_specimens` para rastreio de amostras laboratoriais, com código único por instituição, tipo, recolha, recepção, rejeição e localização.
- Criada `clinical.imaging_studies` para estudos RIS, modalidade, accession number, execução, relatório, validação e metadados DICOM.
- Chaves estrangeiras compostas mantêm os registos ligados à mesma organização e ao pedido diagnóstico original.
- RLS activada nas duas tabelas, com leitura e gestão condicionadas às permissões e ao âmbito de unidade/departamento.
- Triggers impedem associar amostras a pedidos de imagiologia e estudos de imagem a pedidos laboratoriais.
- Índices de fila e de relações principais adicionados.

### Critérios de aceitação / pendentes
- Interface para criar e acompanhar amostras, estudos e relatórios.
- Fluxo de estados transaccionais com histórico imutável de eventos.
- Validação final apenas por profissional activo e habilitado, no departamento correspondente.
- Alertas de valores críticos e controlo de prazos TAT.
- Testes funcionais e de permissões com perfis reais de laboratório e radiologia.
- Integrações externas LIS, analisadores, PACS/DICOMweb e modalidades continuam pendentes; nenhum equipamento foi declarado ligado.

## OT-004 — Farmácia e aprovisionamento

**Estado:** EM EXECUÇÃO — base de dados, APIs seguras e primeira interface operacional implementadas; validação funcional com perfil farmacêutico e circuito de compras pendentes.  
**Prioridade:** Alta.

### Âmbito
- Catálogo de medicamentos e artigos, fornecedores e compras.
- Lotes, validade, localização, entradas, saídas e inventário.
- Prescrição, validação farmacêutica, dispensa e devolução.
- Alertas de ruptura, validade e stock mínimo.
- Ligação a custos, facturação e contabilidade.

### Implementado nesta fase
- Criado o schema pharmacy com catálogo de medicamentos, fornecedores, locais de armazenamento, lotes, prescrições e linhas, dispensas e linhas, movimentos de stock, encomendas e artigos de encomenda.
- RLS activada nas tabelas; permissões específicas para leitura, catálogo, stock, prescrição, dispensa e aprovisionamento.
- APIs de aplicação com autorização e validação; funções transaccionais de entrada de stock e dispensa mantidas no schema operacional.
- Recepção de lote rejeita validade expirada, cria o saldo e o movimento de entrada na mesma transacção.
- Dispensa bloqueia lote expirado/inactivo, quantidade superior ao saldo e quantidade superior ao remanescente prescrito; actualiza lote, dispensa e livro de movimentos atomicamente.
- Interface do módulo Farmácia: catálogo de medicamentos, fornecedores, locais, encomendas em rascunho, aprovação de encomendas, recepção vinculada à encomenda por artigo/lote/validade, dispensa a partir de prescrição activa e consulta de saldos/validade.
- Encomendas criadas em transacção com cabeçalho e artigo; escrita directa nas tabelas de encomenda bloqueada ao cliente.
- Índices de FEFO, histórico de movimentos, prescrições e encomendas; índices de relações e políticas RLS afinados.

### Testes realizados
- Teste autenticado, em transacção revertida, criou medicamento e fornecedor temporários, local de farmácia, recebeu lote e efectuou dispensa; o saldo diminuiu de 7 para 5 e foram criados dois movimentos de stock.
- Teste autenticado de criação de encomenda confirmou cabeçalho em rascunho e linha de artigo.
- Teste transaccional de aprovação e recepção parcial/total: encomenda de 10 unidades aprovada, recepção de 4 e depois 6, estado passou por `partially_received` até `received`, saldo final de stock 10 e tentativa de excesso rejeitada.
- Todos os testes foram revertidos; nenhum medicamento, fornecedor, lote, dispensa ou encomenda de teste ficou persistido.
- Não foram inventados preços comerciais, fornecedores reais ou movimentos reais de stock.

### Pendências / critérios de aceitação finais
- Validar o circuito com conta farmacêutica activa e perfil profissional/cédula confirmados.
- Criar prescrição a partir do acto clínico, com autoria do prescritor e revisão farmacêutica.
- Reconciliação documental com guia/factura do fornecedor e validação por perfil farmacêutico activo; o fluxo técnico de aprovação e recepção parcial/total já está implementado.
- Inventários físicos, ajustes com dupla validação, devoluções, reversões e transferências entre locais.
- Controlo de medicamentos sujeitos a receita especial/controlo legal, registo próprio e segregação de funções.
- Alertas de stock mínimo, validade próxima, recolhas/recalls e cadeia de frio.
- Integração de custo de aquisição, facturação e contabilidade sem duplicar movimentos.
- Testes de permissões com contas farmacêuticas e clínicas reais; nenhuma integração externa foi declarada ligada.

## OT-005 — Enfermagem, internamento, cirurgia e maternidade

**Estado:** PLANEADA.  
**Prioridade:** Alta.

### Âmbito
- Sinais vitais, plano de cuidados, administração de medicação e passagem de turno.
- Admissão, transferência, ocupação de camas, alta e limpeza.
- Bloco operatório, equipa, sala, checklist e consumíveis.
- Maternidade, parto, puerpério e registo neonatal.
- Pediatria e reabilitação.

### Critérios de aceitação
- Impedir dupla ocupação de cama.
- Registar autor, hora e motivo em cada transferência.
- Checklists e consentimentos obrigatórios conforme procedimento.
- Não simular actos clínicos como se fossem cuidados reais.

## OT-006 — Motor financeiro, facturação e AGT / SAF-T AO

**Estado:** EM EXECUÇÃO — motor de cálculo e validação de linhas já preparado; homologação fiscal oficial pendente.  
**Prioridade:** Crítica.

### Âmbito
- Orçamentos, facturas em rascunho, emissão, notas de crédito/débito, recibos e pagamentos.
- Séries, regras fiscais, isenções e impostos por serviço.
- Integração com caixa e contabilidade.
- Exportação SAF-T e validação estrutural.
- Preparação para comunicação AGT, após requisitos e credenciais oficiais.

### Critérios de aceitação
- Totais calculados exclusivamente no servidor.
- Não emitir série fiscal sem comunicação válida e estado fiscal confirmado.
- Não assumir regime fiscal, taxas, credenciais, produtor ou número de validação.
- SAF-T só é considerado válido após geração, validação XSD e conferência com especificação oficial.
- Não declarar homologação AGT sem comprovativo oficial.

## OT-007 — Contabilidade, compras, stocks e gestão

**Estado:** PLANEADA.  
**Prioridade:** Alta.

### Âmbito
- Plano de contas, diários, períodos, lançamentos e estornos.
- Integração automática com facturação, pagamentos, compras e inventário.
- Balancete, razão, demonstrações e fecho.
- Contas a pagar/receber, fornecedores e reconciliação.
- Auditoria e exportação de relatórios.

### Critérios de aceitação
- Débitos iguais a créditos.
- Períodos fechados bloqueiam lançamentos indevidos.
- Rastreabilidade entre lançamento e documento de origem.
- SAF-T contabilístico conciliado com os registos.

## OT-008 — Segurança, desempenho, testes integrados e homologação

**Estado:** PLANEADA.  
**Prioridade:** Crítica.

### Âmbito
- Matriz de permissões por função, departamento e unidade.
- RLS, auditoria, sessões, autenticação e protecção de dados.
- Testes de integração, concorrência, desempenho, recuperação e backups.
- Testes de regressão e aceitação de utilizadores.
- Dossier técnico, evidências e plano de homologação oficial.

### Critérios de aceitação
- Nenhum acesso cruzado entre organizações.
- Nenhum módulo aprovado sem testes funcionais e de permissões.
- Relatórios de testes e falhas resolvidas anexados à OT.
- Homologação interna e homologação AGT identificadas como estados distintos.

## Registo de execução
| 2026-11-12 | OT-004 | Fundação da farmácia e aprovisionamento: catálogo, fornecedores, locais, lotes, prescrições, dispensas, movimentos e encomendas; APIs e interface inicial | migrations OT004 de estrutura, integridade, recepção/dispensa transaccional, API segura, encomendas e ajustes RLS/índices; testes autenticados revertidos aprovados |

| Data | OT | Alteração | Evidência |
|---|---|---|---|
| 2026-11-12 | OT-001 | Emissor IVATAXI de teste e lote de dados registados | Supabase migration + lote TEST-NOVA-ERP-2026-001 |
| 2026-11-12 | OT-001 | Catálogo, camas, diagnóstico e episódios simulados | 42 IDs registados em audit.test_data_registry |
| 2026-11-12 | OT-001 | Pré-visualização de limpeza criada, sem eliminação | audit.preview_test_data_cleanup(uuid) |
| 2026-11-12 | OT-002 | Entrada de urgência sem marcação corrigida e testada; fila mostra triagem pendente | reception_visits + api_get_reception_queue; profissional habilitado pendente |\n| 2026-11-12 | OT-003 | Estruturas LIS de amostras e RIS de estudos de imagem criadas com RLS, escopo institucional e índices | migrations `ot003_lis_specimen_and_ris_imaging_workflow`, `ot003_split_diagnostic_permissions_and_fk_indexes` e `ot003_index_diagnostic_workflow_actors`; RLS, triggers e teste de associação correcta/incorreta concluídos em transacção revertida |\n| 2026-11-12 | OT-003 | Interface do painel diagnóstico ampliada com registo e listagem de amostras e estudos RIS | commit `ea4c06af4b1442e1b0711ff39e982c77f103c353`; deployment de produção `READY` no commit `70d0c93eeeb62949c3cc81a8e49ce2216aaf4d45`; testes funcionais com sessão autenticada ainda pendentes |

