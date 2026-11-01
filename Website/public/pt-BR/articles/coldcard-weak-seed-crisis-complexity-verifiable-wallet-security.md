# A crise das sementes fracas da Coldcard: complexidade não é o mesmo que segurança

Oath Research · September 3, 2026

https://oathwallet.org/pt-BR/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security

O incidente da Coldcard em 2026 não comprometeu remotamente os dispositivos. Ele expôs algo mais fundamental: um invólucro sofisticado não pode proteger uma semente que era previsível desde sua criação.

Nota de pesquisa, 3 de setembro de 2026. Este artigo distingue fatos confirmados, declarações do fornecedor, estimativas on-chain e nossa própria análise. O relatório técnico post-mortem formal da Coinkite ainda não havia sido publicado quando este artigo foi preparado. Os totais das perdas mudaram à medida que investigadores atribuíram transações adicionais; portanto, os números abaixo são retratos datados, e não uma contabilização final.

Em julho de 2026, Bitcoin desapareceu de milhares de endereços cujos proprietários acreditavam que suas chaves estavam protegidas por carteiras de hardware Coldcard. A primeira e mais importante correção também é a mais reveladora: os dispositivos não foram comprometidos remotamente. Um erro de firmware havia enfraquecido a aleatoriedade usada na criação de algumas carteiras. Os invasores podiam percorrer, em outro ambiente, o espaço reduzido de chaves, recuperar possíveis chaves privadas, comparar os endereços derivados com a blockchain pública do Bitcoin e gastar os fundos correspondentes sem tocar no hardware.

Um cofre pode ser fisicamente formidável e, ainda assim, falhar se o segredo colocado dentro dele era previsível desde o início.

É por isso que esse incidente importa muito além de um único fornecedor. Ele contesta um atalho reconfortante: hardware equivale a segurança, mais componentes equivalem a mais proteção e uma longa lista de recursos equivale a um alto grau de garantia. Nenhuma dessas afirmações é um modelo de ameaças. A segurança decorre do sistema completo — entropia, firmware, hardware, processo de compilação, distribuição, interface, backups, comportamento do operador e segurança física — e de evidências que permitam a terceiros testar suas alegações.

## O que aconteceu com a Coldcard

A Coinkite, em seu [aviso oficial](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/), informa que o firmware afetado utilizava um caminho defeituoso de geração de sementes. As sementes de carteiras criadas em dispositivos Mk2 ou Mk3 com firmware da versão 4.0.1 a 4.1.9 estavam em risco, salvo se tivesse sido acrescentada entropia suficiente proveniente de lançamentos de dados privados e independentes, ou se uma passphrase BIP39 forte e exclusiva tivesse criado uma barreira adicional. O aviso também abrange sementes geradas em dispositivos Mk4, Mk5 e Q antes das respectivas versões corrigidas dos canais padrão ou Edge. Para esses dispositivos posteriores, a Coinkite informou cerca de 72 bits de entropia, em vez dos 128 bits pretendidos.

A falha teve origem em um firmware lançado em março de 2021 e permaneceu latente durante anos. A proteção do hardware funcionou sobre o segredo que recebeu; o problema foi que o processo de geração do segredo não forneceu a incerteza esperada. Assim que um invasor podia enumerar sementes plausíveis a um custo viável, a blockchain pública fornecia um teste perfeito de pertinência: derivar endereços, procurar valores e assinar com qualquer chave recuperada. Não eram necessários uma solicitação de phishing, uma sessão USB, uma embalagem roubada nem acesso físico.

### Por que a entropia fraca é catastrófica

Uma semente de carteira não é segura porque parece aleatória para uma pessoa. Ela é segura quando nenhum adversário consegue distinguir nem enumerar, de modo viável, as possibilidades subjacentes. Cada bit de entropia duplica o espaço de busca. Passar de 128 bits para 72 bits não torna uma semente “um pouco mais fraca”; elimina 56 duplicações de trabalho. Um espaço de busca efetivo ainda menor transforma uma busca astronomicamente impossível em um projeto de engenharia.

As palavras de recuperação continuam sintaticamente válidas. Os endereços parecem comuns. O hardware assina normalmente. Os backups são restaurados corretamente. Trata-se de uma falha silenciosa: todo ritual visível pode ser concluído com êxito quando a premissa de segurança já desmoronou. É precisamente por isso que a geração de números aleatórios exige testes determinísticos da integração, instrumentação em dispositivos reais ao redor da fonte de entropia e evidências de lançamento que vinculem o código-fonte revisado ao firmware distribuído.

### O furto ocorreu em ondas

Em 30 de julho, a primeira varredura relatada transferiu aproximadamente 594 BTC de cerca de 500 endereços em aproximadamente 25 minutos. Atribuições posteriores ampliaram o incidente. Uma [avaliação da TRM Labs publicada em 5 de agosto](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) descreveu um total provisório próximo de 1.816 BTC — cerca de USD 116 milhões naquele momento — provenientes de mais de 5.200 endereços, em quatro ondas. Outros investigadores usaram regras de confirmação diferentes e, mais tarde, relataram totais um pouco distintos. Portanto, esses números devem ser lidos como evidência da escala, e não como um registro final consolidado.

A Coinkite, em sua [página atual de status de segurança](https://coldcard.com/security/status), declara explicitamente que o relatório post-mortem formal continua em elaboração e não afirma que cada perda relatada tenha sido atribuída individualmente. Essa incerteza não é motivo para minimizar o incidente. É motivo para preservar a diferença entre mecanismo verificado, transações observadas, atribuição analítica e conclusão forense final.

## Atualizar o firmware não corrige uma semente antiga

Este é o fato operacional que os usuários afetados não podem ignorar. O firmware corrigido corrige a geração futura de sementes; não pode acrescentar entropia retroativamente a uma semente que já existe. Uma carteira restaurada a partir dessa semente em um novo hardware continua controlada pelo mesmo segredo vulnerável. Substituir o invólucro metálico, instalar um aplicativo móvel ou transferir as palavras para outra marca não altera a chave. Os fundos precisam ser transferidos para endereços derivados de uma semente recém-gerada e protegida de forma independente.

Conforme verificado em 3 de setembro de 2026, a página de status da Coldcard indicava Mk4/Mk5 padrão 5.6.1 e Q padrão 1.5.1Q como as versões padrão recomendadas. As versões mínimas corrigidas eram Mk2/Mk3 4.2.0 ou posterior; Mk4/Mk5 padrão 5.6.0 ou posterior; Q padrão 1.5.0Q ou posterior; Mk4/Mk5 Edge 6.6.0X ou posterior; e Q Edge 6.6.0QX ou posterior. Os canais de lançamento importam: uma versão Edge numericamente superior não equivale automaticamente a uma versão padrão corrigida.

### Se houver a possibilidade de você ter sido afetado

- 

Pare de confiar no invólucro. Determine o modelo, o canal de lançamento, o firmware usado quando a semente foi gerada e se a exceção oficial relativa a lançamentos independentes de dados se aplica claramente. Em caso de dúvida, trate a semente como afetada.

- 

Siga apenas as instruções oficiais. Abra diretamente o aviso e a página de status de segurança da Coldcard, verifique o firmware assinado e os hashes publicados e rejeite qualquer “ajuda para migração” não solicitada. Nenhum prestador legítimo de assistência precisa de sua frase de recuperação.

- 

Crie uma semente inteiramente nova em um ambiente corrigido. Não edite, embaralhe nem acrescente palavras à frase antiga. Uma nova carteira precisa de nova entropia. Para um saldo significativo, considere uma implementação independente ou uma política de múltiplas assinaturas corretamente projetada, para que o caminho de geração de sementes de um único fornecedor não seja a única raiz de confiança.

- 

Verifique a recuperação antes de depositar fundos. Registre o backup de forma privada, realize a recuperação em um processo controlado e confirme a impressão digital pública esperada ou o endereço de recebimento esperado. Um backup que nunca foi testado é uma suposição.

- 

Transfira primeiro um pequeno valor de teste; depois, o restante. Verifique o destino e a confirmação antes de transferir o saldo integral. Evite improvisar com pressa, mas não confunda um procedimento sereno com permissão para adiar a migração de uma semente exposta.

- 

Aposente a semente antiga. Uma atualização de firmware e uma passphrase forte acrescentada posteriormente não a corrigem. Guarde os registros necessários para fins tributários ou jurídicos sem conservar cópias desnecessárias do segredo.

A Coinkite afirma que pelo menos 50 lançamentos de dados não viciados, independentes e privados, no fluxo Add Dice Rolls afetado, forneceram, por si sós, pelo menos 128 bits de entropia; 99 ou mais forneceram cerca de 256 bits. As condições exatas importam. Se a sequência foi registrada, observada, enviesada, não independente ou incerta, não invente segurança a partir da contagem. Uma passphrase BIP39 forte e preexistente pode acrescentar uma barreira, mas a Coinkite ainda recomenda a migração e não afirma que uma passphrase corrige a semente.

## O dispositivo não foi hackeado — e esse é o alerta mais profundo

Chamar toda perda de “hack de carteira de hardware” comprime várias classes diferentes de falhas em uma única expressão dramática. Isso obscurece os controles que teriam ajudado. No incidente da Coldcard, o invasor não derrotou o gabinete, o teclado numérico, os controles USB nem o elemento seguro que estavam em posse de cada vítima. O invasor contornou o dispositivo porque o segredo-raiz era enumerável.

Um limite de segurança protege apenas aquilo que o atravessa. Se a chave que entra em um elemento seguro é fraca, se um firmware malicioso a vaza por meio de assinaturas, se a tela exibe um destino controlado por um invasor ou se uma pessoa é coagida a autorizar uma transferência, a existência de hardware dedicado não constitui resposta ao ataque.

## As perdas com carteiras de hardware não são todas iguais

Vários incidentes documentados e demonstrações de pesquisa mostram por que essa categoria exige precisão. Eles não provam que as carteiras de hardware sejam inúteis. Mostram que o hardware transfere o risco para um sistema diferente, composto por chips, firmware, cadeias de suprimentos, software hospedeiro, protocolos de assinatura, backups e procedimentos humanos.

### 1. Injeção de falhas e extração física da semente

Em 2020, o [Kraken Security Labs divulgou](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) uma técnica de injeção de falhas por variação abrupta de tensão contra dispositivos Trezor One e Model T. A Kraken informou que aproximadamente 15 minutos de acesso físico poderiam possibilitar a extração de material criptografado da semente e que um PIN curto poderia então ser quebrado por força bruta. A medida prática de mitigação era uma passphrase BIP39 forte, não armazenada no dispositivo. A Kraken documentou uma classe semelhante de ataque contra a KeepKey.

Essa é uma ameaça diferente da enfrentada pela Coldcard. Ela exige a posse do dispositivo-alvo e injeção de falhas em condições de laboratório. Demonstra que a resistência a adulterações depende do microcontrolador e do projeto de armazenamento escolhidos, e que um PIN não é necessariamente um segredo de criptografia com alta entropia.

### 2. Software comprometido ao redor de um dispositivo autêntico de assinatura em hardware

Em dezembro de 2023, o [incidente na cadeia de suprimentos do Ledger Connect Kit](https://www.ledger.com/blog/security-incident-report) injetou código malicioso em dApps que carregavam um pacote comprometido. Segundo a Ledger, o código induziu usuários de EVM a assinar transações que drenavam seus fundos. Os dispositivos de hardware não revelaram espontaneamente suas sementes; o sistema ao redor deles apresentou uma intenção maliciosa a signatários legítimos.

Essa classe de falha explica por que “a chave nunca saiu do dispositivo” é uma condição necessária, mas insuficiente. Uma chave segura pode autorizar fielmente a transação errada quando o usuário, o sistema hospedeiro ou a tela não conseguem entender de modo confiável o que está sendo assinado. Decodificação clara de transações, telas confiáveis, permissões restritas, controles de dependências e resistência à assinatura às cegas fazem parte da segurança da custódia.

### 3. Firmware malicioso que vaza segredos por meio de assinaturas normais

Pesquisadores da Block [publicaram um ataque prático de pesquisa](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) no qual um firmware de carteira comprometido codifica secretamente material sigiloso em assinaturas aparentemente normais. O modelo de ameaças pressupõe o comprometimento do firmware por vias como uma violação da cadeia de suprimentos, ação interna, comprometimento do sistema de compilação ou comprometimento da chave de assinatura. Um air gap não ajuda se a própria transação assinada se torna o canal de exfiltração.

É nesse ponto que compilações reproduzíveis, múltiplos responsáveis independentes pela compilação, dependências fixadas, inicialização segura e diversidade de múltiplas assinaturas ganham relevância. Esses recursos tratam de elos específicos de uma cadeia. Não certificam magicamente o projeto, o código-fonte nem o operador.

### 4. Exposição de backups, substituição de endereços e coação

Muitos furtos reais jamais exploram o silício. Os invasores roubam ou fotografam backups de sementes, substituem um endereço de recebimento, fazem-se passar pelo suporte, comprometem um processo de compra ou envio, obtêm um dispositivo acompanhado de um PIN fraco ou forçam o proprietário a cooperar. Por concepção, a frase de recuperação continua sendo uma credencial mestra portátil: quem a obtiver poderá restaurar a carteira em outro lugar, independentemente de onde esteja o dispositivo original.

## Por que mais complexidade pode piorar a segurança

A complexidade às vezes se justifica. Uma tela separada pode tornar mais confiável a revisão de transações. Um elemento seguro pode elevar o custo da extração física. Múltiplas assinaturas podem eliminar uma única chave como ponto de falha. Contudo, cada mecanismo acrescentado também cria interfaces, estados, caminhos de atualização, dependências, procedimentos de recuperação e suposições. A pergunta correta não é “Isso é complexo?” É “Que ameaça cada componente controla e que novos modos de falha ele introduz?”

O princípio clássico de Saltzer e Schroeder da [economia de mecanismo](https://www.ojp.gov/ncjrs/virtual-library/abstracts/protection-information-computer-systems) afirma que projetos de proteção devem ser tão simples e pequenos quanto possível, para que a inspeção e a compreensão continuem viáveis. A moderna [orientação do NIST sobre segurança de sistemas](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-160v2r1.pdf) trata de modo semelhante a redução da superfície de ataque e os componentes multifuncionais grandes e difíceis de analisar como questões arquitetônicas. Simplicidade não é ausência de controles. É a recusa de acrescentar controles cujo comportamento não possa ser explicado, testado e operado corretamente.

- 

Mais código cria mais defeitos possíveis. Isso também encarece a revisão completa e dificulta o raciocínio sobre as interações.

- 

Mais modos criam riscos de configuração. Firmware padrão versus Edge, diversos fluxos de geração de sementes, carteiras com passphrase, caminhos por USB e air gap e variantes de backup podem, individualmente, ser seguros e, combinados, tornar-se confusos.

- 

Mais interfaces criam riscos de tradução. Uma tela de hardware, um aplicativo hospedeiro, um formato QR, um fluxo de trabalho com microSD, um conector de navegador e um backend de rede precisam concordar exatamente sobre o que o usuário está autorizando.

- 

Mais etapas cerimoniais podem reduzir a adesão. Se o caminho seguro for difícil, as pessoas deixam de fazer verificações, adiam atualizações, reutilizam backups ou seguem instruções de emergência sem compreendê-las.

- 

Mais confiança pode ampliar as perdas. Um produto anunciado como “de armazenamento frio”, “isolado por air gap” ou “impossível de hackear” pode incentivar o usuário a concentrar mais valor sob uma única semente. A concentração transforma um defeito oculto em um resultado catastrófico.

A defesa em profundidade é valiosa quando as camadas são independentes. A repetição da mesma implementação, da mesma fonte de entropia, do mesmo fornecedor ou do mesmo segredo de recuperação não constitui defesa independente.

## Código aberto, auditorias, compilações reproduzíveis e revisão por IA não são sinônimos

O histórico da Coldcard é particularmente instrutivo porque seu firmware era público e existia documentação de compilação reproduzível, enquanto o caminho vulnerável permaneceu nas versões lançadas durante anos. Isso não torna inútil a abertura. Mostra que a disponibilidade de evidências e o exame efetivo da propriedade correta são coisas diferentes.

- 

Código aberto significa que terceiros podem inspecionar a implementação. Não comprova que alguém tenha revisado todos os caminhos críticos para a segurança nem que a árvore pública tenha produzido o binário instalado.

- 

Uma auditoria independente é um trabalho de escopo delimitado. Seu valor depende do revisor identificado, do commit ou da versão exatos, do modelo de ameaças, das propriedades testadas, das exclusões, das constatações e das evidências de remediação. “Auditado” sem escopo é um slogan.

- 

Uma compilação reproduzível permite que equipes independentes sigam uma receita publicada para compilar e comparar os resultados. Uma correspondência pode vincular o código-fonte a um artefato de lançamento; não prova que o código-fonte esteja correto.

- 

A revisão da App Store e a assinatura de código estabelecem controles de distribuição e de plataforma. Por si sós, não provam que um binário da App Store seja equivalente, bit a bit, a um repositório público.

- 

A revisão assistida por IA pode examinar grandes bases de código, gerar hipóteses adversariais, comparar invariantes e acelerar a análise humana. Um modelo também pode deixar de perceber o contexto, aceitar uma premissa falsa ou produzir uma constatação plausível, porém incorreta. A revisão por IA é outra lente, não uma autoridade certificadora.

A página atual de status da Coldcard oferece um bom exemplo de formulação de escopo: menciona instrumentação direcionada do RNG em dispositivos reais, revisões de código-fonte, uma revisão do hotfix e uma compilação reproduzível acompanhada do rastreamento do caminho dos lançamentos de dados; em seguida, declara explicitamente que essas verificações não constituem uma auditoria completa de cada binário de firmware e não garantem a ausência de defeitos. Essa frase tem mais valor do que um selo sem ressalvas.

## O que a Oath pode afirmar com honestidade

A Oath se baseia em uma arquitetura de custódia diferente: um aplicativo para iPhone e iPad com código-fonte disponível, em vez de um dispositivo dedicado de assinatura em hardware. O [repositório público](https://github.com/devdasx/oath-wallet) disponibiliza o cliente móvel e as instruções de compilação sob a licença MIT. O [modelo de segurança publicado](https://oathwallet.org/data/security-model.json) declara que os segredos da carteira são armazenados por meio do Keychain do iOS no escopo do aplicativo, com proteção restrita a este dispositivo, enquanto o banco de dados local mantém referências opacas, e não frases de recuperação ou chaves privadas. As transações são construídas e assinadas no dispositivo antes que os dados assinados sejam enviados à infraestrutura de rede.

A documentação da Apple sobre [segurança da plataforma](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) descreve assinatura obrigatória de código, desenvolvedores identificados, revisão automatizada e humana da App Store, sandboxing e verificação compulsória de assinaturas em tempo de execução. Sua [documentação do Keychain](https://support.apple.com/guide/security/secb0694df1a/1/web/1) descreve a proteção individual de cada item e a participação do Secure Enclave no gerenciamento das chaves do Keychain. Esses são controles reais da plataforma. Não significam que as chaves privadas de blockchain da Oath sejam, elas próprias, chaves do Secure Enclave, e a Oath não faz essa afirmação.

### A Oath pode ser mais segura do que uma carteira de hardware?

Para alguns modelos de ameaça, sim. Como afirmação universal, não. Uma carteira de celular pode dispensar o percurso de fabricação e envio de um dispositivo dedicado, reduzir o número de objetos que sinalizam visivelmente uma custódia de alto valor, usar uma plataforma com atualizações assinadas rápidas e sandboxing maduro e colocar uma implementação inspecionável em uma interface familiar que os usuários têm maior probabilidade de operar corretamente. Uma superfície funcional menor também pode eliminar classes inteiras de riscos relacionados a navegador, swap, aprovação e tradução entre dispositivos.

Para outros modelos de ameaça, um dispositivo de assinatura separado e bem projetado constitui um limite importante. Se o sistema operacional do celular ou o processo da carteira for comprometido, a separação física e uma tela cuja confiabilidade seja independente podem impedir que um sistema hospedeiro conectado à rede obtenha ou utilize indevidamente uma chave. Para valores institucionais ou capazes de mudar o rumo de uma vida, a arquitetura mais robusta pode ser uma política de múltiplas assinaturas cuidadosamente testada, que use implementações independentes, entropia independente, locais separados e recuperação documentada — não uma disputa entre um celular e uma caixa de hardware.

A palavra “hardware”, portanto, jamais deve encerrar a análise. Um iPhone também é hardware. As diferenças relevantes são qual código é executado, como ele foi compilado e distribuído, onde os segredos ficam disponíveis, o que o usuário pode verificar, como as transações são exibidas, como ocorrem as atualizações e quais falhas isoladas podem movimentar fundos.

### O limite das evidências também importa para a Oath

O site da Oath declara atualmente que o aplicativo passa por auditoria independente e é compilado de modo reproduzível. Seu [registro público de auditorias](https://oathwallet.org/security) é indicado como o local canônico para os nomes dos revisores, o escopo exato, as datas, as versões revisadas, os relatórios, as constatações, as correções, os hashes e os materiais de reprodutibilidade. No momento da publicação, esse registro ainda não exibia esses artefatos concretos. O repositório público no GitHub tampouco continha artefatos de versão em relação aos quais fosse possível reproduzir, de modo independente, a correspondência com um binário da App Store.

Portanto, este artigo não afirma que “foi comprovada a segurança de cada linha do binário da App Store”, que várias empresas tenham certificado todos os comportamentos ou que a IA tenha verificado todo o aplicativo. Essas afirmações excederiam as evidências públicas disponíveis. A distinção tecnicamente correta é que o código-fonte está publicado no GitHub, enquanto a Apple distribui pela App Store um binário compilado e assinado. Vincular os dois exige uma receita pública de compilação, uma revisão imutável do código-fonte, um bloqueio de dependências, um artefato obtido da App Store, um procedimento de normalização dos efeitos da assinatura da Apple, um resultado correspondente e uma atestação independente.

A verificação é mais robusta quando uma afirmação inclui evidências suficientes para que um terceiro cético possa reproduzi-la. A Oath deve ser julgada por esse padrão com o mesmo rigor aplicado a qualquer fornecedor de carteiras de hardware.

## O que um pacote de verificação de nível universitário deve conter

Para pesquisadores, auditores, jornalistas e avaliadores institucionais, uma alegação confiável de segurança de carteira deve constituir uma cadeia navegável de evidências, e não uma coleção de selos. No mínimo, solicite:

- 

Um modelo de ameaças preciso. Discrimine comprometimento remoto, extração física, atualizações maliciosas, comprometimento do sistema de compilação, entropia fraca, substituição de transações, furto de backups, coação e disponibilidade.

- 

Uma revisão de código imutável e examinada. Identifique o commit, o grafo de dependências, as versões do compilador e do SDK, os sinalizadores de compilação, os entitlements e a configuração que integraram o escopo.

- 

Um relatório independente com autoria identificada. Publique o revisor, a metodologia, as datas, as exclusões, os critérios de gravidade, as constatações e as evidências usadas para dar por concluída cada remediação.

- 

Reprodutibilidade do código-fonte ao binário. Forneça uma receita completa e resultados de compilações independentes vinculados à versão pública exata. Explique quaisquer diferenças não determinísticas ou geradas pela assinatura.

- 

Evidências do caminho de entropia. Teste a fonte de entropia em hardware real, verifique o comportamento diante de falhas, rejeite qualquer caminho alternativo silencioso e rastreie o caminho exato usado pela compilação da versão lançada. Testes estatísticos apenas na saída não podem provar que o gerador foi integrado corretamente.

- 

Testes adversariais de transações. Teste substituição de destinatário, manipulação de taxas, metadados hostis, limites da assinatura às cegas, transmissões interrompidas e divergências entre os analisadores sintáticos de cada tela e dispositivo de assinatura.

- 

Exercícios de recuperação e atualização. Teste as instruções sob pressão de tempo realista, incluindo informações parciais, versões antigas, migração, dispositivos perdidos e a possibilidade de uma atualização não poder corrigir segredos existentes.

- 

Revisão contínua e diversificada. Use testes determinísticos, análise estática, especialistas humanos, fuzzing, testes em dispositivos reais e revisão assistida por IA como métodos complementares. Registre o que cada método estabeleceu e o que não estabeleceu.

## A ameaça pode sair da tela

A autocustódia pode eliminar um custodiante, mas também pode transformar uma pessoa no limite final de autorização. Um ladrão incapaz de romper a criptografia pode, em vez disso, ter como alvo o proprietário, sua família, sua residência, seu local de trabalho ou sua identidade pública. Às vezes, o hardware dedicado pode facilitar essa escolha de alvo ao anunciar visivelmente que uma pessoa leva a custódia a sério ou ao criar um objeto físico que o invasor espera encontrar. Um celular também pode revelar os ativos se os saldos estiverem visíveis. Nenhum dos dois formatos resolve a coação.

Um estudo de 2024 revisado por pares, [“Investigação de ataques de chave inglesa: ataques físicos dirigidos a usuários de criptomoedas”](https://doi.org/10.4230/LIPIcs.AFT.2024.10), analisou entrevistas, fóruns e 146 reportagens. Seu conjunto filtrado de notícias continha 105 incidentes de ataques físicos, entre os quais sequestro foi o ato predominante relatado em 24 casos e homicídio em 6. Os autores ressaltam a subnotificação e constataram que profissionais de segurança experientes não estavam imunes. Esses números descrevem o conjunto de dados do estudo, não a taxa de incidência mundial nem a prova de que um tipo específico de carteira tenha causado cada crime.

O perigo não é teórico. Em 2024, o [Departamento de Justiça dos Estados Unidos](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) descreveu condenações relacionadas a uma conspiração que empregou vigilância, invasões de domicílio, sequestro, agressão e ameaças para forçar vítimas a esvaziar contas de criptomoedas. A lição não é entrar em pânico nem se esconder de ajuda legítima. É tratar a privacidade operacional e a segurança pessoal como partes do projeto de uma carteira.

### A segurança humana tem precedência sobre a recuperação de ativos

- 

Não divulgue saldos nem detalhes de armazenamento. Endereços públicos, capturas de tela, conversas em conferências, publicações em redes sociais, registros de envio e embalagens descartadas podem vincular identidade, localização e riqueza percebida.

- 

Separe os fundos cotidianos das reservas. Uma carteira de gastos não deve revelar nem controlar toda a posição de longo prazo. Evite concentrar todos os ativos e caminhos de recuperação sob um único segredo imediatamente acessível.

- 

Use autorização independente para valores significativos. Uma política de múltiplas assinaturas bem projetada pode impedir que um dispositivo roubado ou um único local submetido a coação seja suficiente, mas somente quando as chaves, as implementações e os materiais de recuperação estiverem genuinamente separados.

- 

Proteja o que a interface revela. Use o bloqueio do aplicativo e os controles de privacidade do seletor de apps, evite exibir saldos integrais em público e verifique os destinatários sem expor ativos não relacionados.

- 

Planeje com profissionais locais qualificados. Pessoas e instituições de alto risco devem desenvolver procedimentos lícitos de segurança física, viagem, resposta a incidentes, planejamento sucessório e segurança familiar com especialistas que compreendam sua jurisdição e suas circunstâncias pessoais.

- 

Nunca arrisque uma vida por uma carteira. Nenhuma frase de recuperação, dispositivo, transação ou quantia vale uma lesão física. Diante de uma ameaça imediata, priorize a segurança humana e contate os serviços locais de emergência quando for seguro fazê-lo.

## A lição está nas evidências, não na lealdade tribal

A falha da Coldcard não prova que toda Coldcard atual seja insegura, que toda carteira de hardware seja mero teatro ou que toda carteira de celular seja superior. A Coinkite publicou versões corrigidas, orientações de migração, validação independente direcionada e limites explícitos para aquilo que essas verificações estabelecem. Uma análise responsável deve reconhecer tanto a gravidade do incidente quanto o histórico de correção.

Da mesma forma, a Oath não deve herdar confiança apenas por criticar outra arquitetura. Seu código-fonte público, seu modelo enxuto de custódia, os controles da plataforma Apple, a assinatura local e a possibilidade de revisão são elementos significativos. Eles ganham força quando um terceiro identificado publica o escopo e as constatações, quando pesquisadores conseguem reproduzir o binário distribuído a partir de código-fonte imutável e quando a revisão assistida por IA é combinada com testes determinísticos e julgamento humano responsável.

A conclusão duradoura é mais simples: a segurança não está no material da caixa; está na qualidade do segredo, no comportamento do sistema completo, na independência de suas defesas, na clareza de sua interface e nas evidências disponíveis para verificar cada afirmação importante. A complexidade pode ser necessária, mas precisa justificar sua presença, uma ameaça controlada por vez.

Continue com os guias da Oath sobre [Create your first wallet](https://help.oathwallet.org/articles/create-wallet), [passphrases BIP39](https://oathwallet.org/articles/add-bip39-passphrase-oath-wallet), [o modelo de segurança de autocustódia](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model) e [controles de código de acesso e privacidade do aplicativo](https://oathwallet.org/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy).

## Fontes primárias e técnicas

- 

[Coinkite: aviso de segurança da Coldcard](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) — versões afetadas, escopo da entropia, versões corrigidas e orientações de migração.

- 

[Coldcard: status atual de segurança](https://coldcard.com/security/status) — versões atuais, escopo da validação independente, limitações e status do post-mortem.

- 

[TRM Labs: avaliação on-chain de 5 de agosto](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) — estimativa datada das perdas e análise do fluxo de transações.

- 

[Kraken Security Labs: divulgação sobre injeção de falhas em dispositivos Trezor](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) — extração de semente mediante acesso físico e mitigação por passphrase.

- 

[Ledger: relatório do incidente do Connect Kit](https://www.ledger.com/blog/security-incident-report) — publicação de dependência maliciosa e impacto sobre assinaturas de usuários.

- 

[Block: pesquisa sobre backdoor em firmware](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) — exfiltração de segredos por meio de assinaturas e mitigações na cadeia de suprimentos.

- 

[Segurança da Plataforma Apple: segurança de apps e assinatura de código](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) — distribuição no iOS, sandboxing e controles de integridade em tempo de execução.

- 

[Ordekian, Atondo-Siu, Hutchings e Vasek: estudo sobre ataques de chave inglesa](https://doi.org/10.4230/LIPIcs.AFT.2024.10) — análise de segurança física revisada por pares.

- 

[Departamento de Justiça dos EUA: condenações por invasões de domicílio relacionadas a criptomoedas](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) — coação física e vigilância documentadas.

A Oath não é afiliada à Coldcard, à Coinkite, à Trezor, à Kraken, à Ledger, à Block nem aos pesquisadores citados, tampouco é endossada por eles. Os nomes de produtos e empresas pertencem a seus respectivos proprietários. Este artigo é material educativo sobre segurança, não orientação financeira, jurídica ou emergencial individualizada. Nunca forneça uma frase de recuperação, chave privada, passphrase de carteira, código de acesso do aplicativo ou senha de backup a um site, agente de suporte, pesquisador ou assistente de IA.
