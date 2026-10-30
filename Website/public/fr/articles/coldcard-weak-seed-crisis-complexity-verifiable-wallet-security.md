# La crise des graines faibles de Coldcard : la complexité n’est pas synonyme de sécurité

Oath Research · September 3, 2026

https://oathwallet.org/fr/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security

L’incident Coldcard de 2026 n’a entraîné aucune compromission à distance des appareils. Il a mis au jour une réalité plus fondamentale : un boîtier sophistiqué ne peut protéger une graine qui était prévisible dès sa création.

Note de recherche, 3 septembre 2026. Cet article distingue les faits confirmés, les déclarations du fournisseur, les estimations tirées de la chaîne et notre propre analyse. Le rapport technique post-mortem officiel de Coinkite n’avait toujours pas été publié lors de la préparation de cet article. Le montant total des pertes a évolué à mesure que les enquêteurs ont attribué des transactions supplémentaires ; les chiffres ci-dessous constituent donc des instantanés datés, et non un bilan définitif.

En juillet 2026, des bitcoins ont disparu de milliers d’adresses dont les propriétaires pensaient que leurs clés étaient protégées par des portefeuilles matériels Coldcard. La première rectification, et la plus importante, est aussi la plus révélatrice : les appareils n’ont pas été compromis à distance. Une erreur du micrologiciel avait affaibli l’aléa utilisé lors de la création de certains portefeuilles. Les attaquants pouvaient explorer ailleurs l’espace de clés réduit, retrouver des clés privées candidates, comparer les adresses dérivées à la blockchain Bitcoin publique et dépenser les fonds correspondants sans toucher au matériel.

Un coffre-fort peut être physiquement redoutable et néanmoins faillir si le secret qu’il renferme était prévisible dès le départ.

Voilà pourquoi cet incident importe bien au-delà d’un seul fournisseur. Il remet en cause un raccourci rassurant : matériel égale sécurité, davantage de composants égale davantage de protection, et une longue liste de fonctionnalités égale un niveau élevé d’assurance. Aucune de ces affirmations ne constitue un modèle de menace. La sécurité résulte du système complet — entropie, micrologiciel, matériel, processus de compilation, distribution, interface, sauvegardes, comportement de l’opérateur et sécurité physique — ainsi que des éléments probants qui permettent à des tiers d’en vérifier les affirmations.

## Ce qui est arrivé à Coldcard

La [avis officiel de Coinkite](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) indique que les micrologiciels concernés empruntaient un chemin défectueux de génération de la graine. Les graines de portefeuilles créées sur des Mk2 ou Mk3 avec les micrologiciels 4.0.1 à 4.1.9 étaient exposées, sauf si une entropie suffisante, privée et indépendante, avait été ajoutée au moyen de dés, ou si une phrase secrète BIP39 robuste et unique avait créé une barrière supplémentaire. L’avis vise également les graines générées sur des appareils Mk4, Mk5 et Q avant leurs versions Standard ou Edge corrigées. Pour ces appareils ultérieurs, Coinkite a fait état d’environ 72 bits d’entropie au lieu des 128 bits prévus.

La défaillance provenait d’un micrologiciel publié en mars 2021 et est demeurée latente pendant des années. La protection matérielle a bien opéré sur le secret qui lui avait été confié ; le problème tenait à ce que le processus de génération du secret n’offrait pas l’incertitude attendue. Dès lors qu’un attaquant pouvait énumérer des graines plausibles à un coût praticable, la blockchain publique fournissait un test d’appartenance parfait : dériver des adresses, y rechercher de la valeur et signer avec toute clé retrouvée. Aucune invite d’hameçonnage, session USB, colis volé ni aucun accès physique n’était nécessaire.

### Pourquoi une faible entropie est catastrophique

Une graine de portefeuille n’est pas sûre parce qu’elle paraît aléatoire à une personne. Elle l’est lorsqu’aucun adversaire ne peut, en pratique, distinguer ou énumérer les possibilités sous-jacentes. Chaque bit d’entropie double l’espace de recherche. Passer de 128 bits à 72 bits ne rend pas une graine « un peu plus faible » ; cela retranche 56 doublements de travail. Un espace de recherche effectif encore plus restreint transforme une recherche astronomiquement impossible en projet d’ingénierie.

Les mots de récupération restent syntaxiquement valides. Les adresses paraissent ordinaires. Le matériel signe normalement. Les sauvegardes se restaurent correctement. C’est une défaillance silencieuse : chaque rituel visible peut réussir alors que le postulat de sécurité s’est déjà effondré. C’est précisément pourquoi la génération de nombres aléatoires exige des tests déterministes du câblage, une instrumentation sur appareils réels autour de la source d’entropie et des preuves de publication qui relient le code source examiné au micrologiciel distribué.

### Le vol s’est déroulé par vagues

Le 30 juillet, le premier balayage signalé a déplacé environ 594 BTC depuis quelque 500 adresses en approximativement 25 minutes. Des attributions ultérieures ont élargi le périmètre de l’incident. Une [analyse de TRM Labs publiée le 5 août](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) faisait état d’un total provisoire proche de 1,816 BTC — soit environ USD 116 millions à cet instant — provenant de plus de 5,200 adresses, en quatre vagues. D’autres enquêteurs ont appliqué des règles de confirmation différentes et publié par la suite des totaux quelque peu divergents. Ces chiffres doivent donc être lus comme des indications de l’ampleur, et non comme un registre définitif arrêté.

La [page actuelle de suivi de la sécurité de Coinkite](https://coldcard.com/security/status) indique explicitement que le rapport post-mortem officiel est toujours en cours de préparation et n’affirme pas que chaque perte signalée a été attribuée individuellement. Cette incertitude ne justifie pas de minimiser l’incident. Elle impose de préserver la distinction entre le mécanisme vérifié, les transactions observées, l’attribution analytique et la conclusion définitive de l’analyse forensique.

## La mise à jour du micrologiciel ne répare pas une ancienne graine

C’est le fait opérationnel que les utilisateurs concernés ne doivent surtout pas manquer. Un micrologiciel corrigé rectifie la génération future de graines ; il ne peut ajouter rétroactivement de l’entropie à une graine qui existe déjà. Un portefeuille restauré à partir de cette graine sur un nouveau matériel reste contrôlé par le même secret vulnérable. Remplacer le boîtier métallique, installer une application mobile ou transférer les mots vers une autre marque ne change pas la clé. Les fonds doivent être déplacés vers des adresses dérivées d’une graine nouvellement générée et protégée de manière indépendante.

À la date de vérification du 3 septembre 2026, la page d’état de Coldcard indiquait Mk4/Mk5 Standard 5.6.1 et Q Standard 1.5.1Q comme versions Standard recommandées. Les versions corrigées minimales étaient Mk2/Mk3 4.2.0 ou ultérieure ; Mk4/Mk5 Standard 5.6.0 ou ultérieure ; Q Standard 1.5.0Q ou ultérieure ; Mk4/Mk5 Edge 6.6.0X ou ultérieure ; et Q Edge 6.6.0QX ou ultérieure. Les canaux de publication ont leur importance : une version Edge portant un numéro supérieur n’équivaut pas automatiquement à une version Standard corrigée.

### Si vous êtes susceptible d’être concerné

- 

Cessez de vous fier au boîtier. Déterminez le modèle, le canal de publication, le micrologiciel employé lors de la génération de la graine et si l’exception officielle relative à des dés indépendants s’applique sans ambiguïté. En cas de doute, considérez la graine comme concernée.

- 

Ne suivez que les instructions officielles. Ouvrez directement l’avis Coldcard et la page de suivi de la sécurité, vérifiez le micrologiciel signé et les empreintes publiées, et refusez toute « aide à la migration » non sollicitée. Aucun intervenant légitime n’a besoin de votre phrase de récupération.

- 

Créez une graine entièrement nouvelle dans un environnement corrigé. Ne modifiez pas l’ancienne phrase, n’en réordonnez pas les mots et n’y ajoutez rien. Un nouveau portefeuille exige une nouvelle entropie. Pour un solde important, envisagez une implémentation indépendante ou une politique multisignature convenablement conçue, afin que le chemin de génération de graine d’un seul fournisseur ne soit pas l’unique racine de confiance.

- 

Vérifiez la récupération avant de déposer des fonds. Consignez la sauvegarde de manière confidentielle, restaurez-la selon une procédure maîtrisée et confirmez l’empreinte publique ou l’adresse de réception attendue. Une sauvegarde jamais testée n’est qu’une hypothèse.

- 

Effectuez d’abord un petit transfert d’essai, puis transférez le reste. Vérifiez la destination et la confirmation avant de déplacer l’intégralité du solde. Évitez toute improvisation précipitée, mais ne confondez pas une procédure calme avec l’autorisation de différer le traitement d’une graine exposée.

- 

Mettez l’ancienne graine hors service. Une mise à jour du micrologiciel et une phrase secrète robuste ajoutée ultérieurement ne la réparent pas. Conservez les documents nécessaires à des fins fiscales ou juridiques sans garder de copies superflues du secret.

Coinkite indique qu’au moins 50 lancers de dés équitables, indépendants et privés, effectués dans le processus Add Dice Rolls concerné, apportaient au moins 128 bits provenant des seuls dés ; 99 lancers ou davantage en apportaient environ 256. Les conditions exactes sont déterminantes. Si la séquence a été enregistrée, observée, biaisée, non indépendante ou demeure incertaine, ne déduisez pas sa sûreté du seul décompte. Une phrase secrète BIP39 robuste et préexistante peut ajouter une barrière, mais Coinkite recommande néanmoins la migration et ne présente pas une phrase secrète comme un moyen de réparer la graine.

## L’appareil n’a pas été piraté — et c’est là l’avertissement le plus profond

Qualifier chaque perte de « piratage de portefeuille matériel » réduit plusieurs catégories de défaillances distinctes à une formule spectaculaire. Cela masque les mesures de contrôle qui auraient pu être utiles. Dans l’incident Coldcard, l’attaquant n’a vaincu ni le boîtier, ni le clavier, ni les contrôles USB, ni l’élément sécurisé en possession de chaque victime. Il a contourné l’appareil parce que le secret racine pouvait être énuméré.

Une frontière de sécurité ne protège que ce qui la franchit. Si la clé qui entre dans un élément sécurisé est faible, si un micrologiciel malveillant la divulgue au moyen de signatures, si l’écran affiche une destination contrôlée par un attaquant, ou si une personne est contrainte d’autoriser un transfert, l’existence d’un matériel dédié n’apporte aucune réponse à l’attaque.

## Les pertes liées aux portefeuilles matériels ne se ressemblent pas toutes

Plusieurs incidents documentés et démonstrations de recherche montrent pourquoi cette catégorie exige de la précision. Ils ne prouvent pas que les portefeuilles matériels sont inutiles. Ils montrent que le matériel déplace le risque vers un autre système, composé de puces, de micrologiciels, de chaînes d’approvisionnement, de logiciels hôtes, de protocoles de signature, de sauvegardes et de procédures humaines.

### 1. Injection de fautes et extraction physique de la graine

En 2020, [Kraken Security Labs a révélé](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) une technique de perturbation de tension visant les appareils Trezor One et Model T. Selon Kraken, environ 15 minutes d’accès physique pouvaient permettre l’extraction de données de graine chiffrées, après quoi un PIN court pouvait être attaqué par force brute. La mesure d’atténuation pratique proposée était une phrase secrète BIP39 robuste, non stockée sur l’appareil. Kraken a documenté une catégorie d’attaque analogue contre KeepKey.

Cette menace est différente de celle de Coldcard. Elle exige de posséder l’appareil visé et de procéder à une injection de fautes de type laboratoire. Elle montre que la résistance aux altérations dépend du microcontrôleur et de l’architecture de stockage retenus, et qu’un PIN n’est pas nécessairement un secret de chiffrement à forte entropie.

### 2. Compromission des logiciels entourant un dispositif de signature matériel authentique

En décembre 2023, l’[incident touchant la chaîne d’approvisionnement de Ledger Connect Kit](https://www.ledger.com/blog/security-incident-report) a injecté du code malveillant dans les dApps qui chargeaient un paquet compromis. Selon Ledger, ce code a incité des utilisateurs EVM à signer des transactions qui vidaient leurs comptes. Les appareils matériels n’ont pas spontanément révélé leurs graines ; le système qui les entourait a présenté une intention malveillante à des signataires légitimes.

Cette catégorie de défaillance explique pourquoi « la clé n’a jamais quitté l’appareil » est une condition nécessaire, mais insuffisante. Une clé sûre peut fidèlement autoriser la mauvaise transaction lorsque l’utilisateur, l’hôte ou l’écran ne permet pas de comprendre de façon fiable ce qui est signé. Un décodage clair des transactions, des écrans dignes de confiance, des autorisations étroites, la maîtrise des dépendances et la résistance à la signature aveugle font partie de la sécurité de la conservation autonome.

### 3. Un micrologiciel malveillant qui divulgue les secrets au moyen de signatures normales

Des chercheurs de Block ont [publié une attaque expérimentale applicable en pratique](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) dans laquelle un micrologiciel de portefeuille compromis encode subrepticement des données secrètes dans des signatures apparemment normales. Leur modèle de menace suppose une compromission du micrologiciel par des voies telles qu’une atteinte à la chaîne d’approvisionnement, l’action d’un initié, la compromission du système de compilation ou celle d’une clé de signature. Une isolation physique ne sert à rien si la transaction signée devient elle-même le canal d’exfiltration.

C’est ici que les compilations reproductibles, les équipes de compilation indépendantes, les dépendances épinglées, le démarrage sécurisé et la diversité multisignature prennent tout leur sens. Ces mesures traitent des maillons précis d’une chaîne. Elles ne certifient pas magiquement la conception, le code source ni l’opérateur.

### 4. Exposition de sauvegardes, substitution d’adresses et coercition

De nombreux vols réels n’exploitent jamais le silicium. Les attaquants dérobent ou photographient des sauvegardes de graines, substituent une adresse de réception, usurpent l’identité de l’assistance, compromettent un processus d’achat ou d’expédition, obtiennent un appareil accompagné d’un PIN faible, ou contraignent le propriétaire à coopérer. Par conception, la phrase de récupération reste un secret d’accès maître et portable : quiconque l’obtient peut restaurer le portefeuille ailleurs, quel que soit l’endroit où se trouve l’appareil d’origine.

## Pourquoi une complexité accrue peut dégrader la sécurité

La complexité est parfois justifiée. Un écran distinct peut rendre l’examen des transactions plus fiable. Un élément sécurisé peut accroître le coût d’une extraction physique. Le multisignature peut éviter qu’une seule clé constitue le point de défaillance. Toutefois, chaque mécanisme ajouté crée aussi des interfaces, des états, des chemins de mise à jour, des dépendances, des procédures de récupération et des hypothèses. La bonne question n’est pas « Est-ce complexe ? », mais « Quelle menace chaque composant maîtrise-t-il, et quels nouveaux modes de défaillance introduit-il ? »

Le principe classique de Saltzer et Schroeder dit d’[économie de mécanisme](https://www.ojp.gov/ncjrs/virtual-library/abstracts/protection-information-computer-systems) veut que les mécanismes de protection soient aussi simples et réduits que possible, afin que leur inspection et leur compréhension restent praticables. Les [recommandations du NIST en matière de sécurité des systèmes](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-160v2r1.pdf) considèrent de même la réduction de la surface d’attaque et les composants multifonctions volumineux, difficiles à analyser, comme des préoccupations architecturales. La simplicité n’est pas l’absence de contrôles. Elle est le refus d’ajouter des contrôles dont le comportement ne peut être expliqué, testé et exploité correctement.

- 

Davantage de code crée davantage de défauts possibles. Il rend aussi un examen exhaustif plus coûteux et complique le raisonnement sur les interactions.

- 

Multiplier les modes accroît le risque de configuration. Les micrologiciels Standard et Edge, les différents processus de génération de graines, les portefeuilles à phrase secrète, les chemins USB et isolés du réseau, ainsi que les variantes de sauvegarde, peuvent chacun être sûrs séparément tout en prêtant à confusion lorsqu’ils sont combinés.

- 

Multiplier les interfaces accroît le risque de traduction. Un écran matériel, une application hôte, un format QR, un processus microSD, un connecteur de navigateur et une infrastructure réseau doivent s’accorder exactement sur ce que l’utilisateur autorise.

- 

Multiplier les rituels peut réduire le respect des procédures. Si le chemin sûr est difficile, les utilisateurs omettent les vérifications, reportent les mises à jour, réutilisent des sauvegardes ou suivent des consignes d’urgence sans les comprendre.

- 

Une confiance accrue peut amplifier la perte. Un produit présenté comme « à froid », « isolé du réseau » ou « inviolable » peut inciter un utilisateur à concentrer davantage de valeur derrière une seule graine. Cette concentration transforme un défaut caché unique en issue catastrophique.

La défense en profondeur est précieuse lorsque les couches sont indépendantes. Répéter la même implémentation, la même source d’entropie, le même fournisseur ou le même secret de récupération ne constitue pas une défense indépendante.

## Le code source ouvert, les audits, les compilations reproductibles et la revue par l’IA ne sont pas synonymes

Le cas de Coldcard est particulièrement instructif : son micrologiciel était public et une documentation relative aux compilations reproductibles existait, tandis que le chemin vulnérable est resté présent dans les versions publiées pendant des années. Cela ne rend pas l’ouverture inutile. Cela montre que la disponibilité des preuves et l’examen effectif de la bonne propriété sont deux choses différentes.

- 

Le code source ouvert signifie que des tiers peuvent examiner l’implémentation. Il n’établit pas que quelqu’un a examiné chaque chemin critique pour la sécurité, ni que l’arborescence publique a produit le binaire installé.

- 

Un audit indépendant est une mission circonscrite. Sa valeur dépend du nom de l’auditeur, du commit ou de la version exacts, du modèle de menace, des propriétés testées, des exclusions, des constats et des preuves de remédiation. La mention « audité » sans périmètre n’est qu’un slogan.

- 

Une compilation reproductible permet à des parties indépendantes de suivre une recette publiée et de comparer les résultats. Une correspondance peut relier le code source à un artefact de publication ; elle ne prouve pas que le code source est correct.

- 

L’examen par l’App Store et la signature du code établissent des contrôles de distribution et de plateforme. Ils ne prouvent pas, à eux seuls, qu’un binaire de l’App Store est identique bit pour bit à un dépôt public.

- 

La revue assistée par l’IA peut parcourir de vastes bases de code, formuler des hypothèses adversariales, comparer des invariants et accélérer l’analyse humaine. Un modèle peut aussi manquer un élément de contexte, accepter une prémisse fausse ou produire un constat plausible mais erroné. La revue par l’IA offre un angle d’analyse supplémentaire ; elle n’est pas une autorité de certification.

La page actuelle de suivi de la sécurité de Coldcard offre un bon modèle de formulation du périmètre : elle mentionne une instrumentation ciblée du RNG sur des appareils réels, des revues du code source, une revue du correctif d’urgence, ainsi qu’une compilation reproductible assortie d’un traçage du chemin de traitement des dés ; elle précise ensuite explicitement que ces contrôles ne constituent pas un audit complet de chaque binaire du micrologiciel et ne garantissent pas l’absence de défauts. Cette phrase vaut davantage qu’un badge sans réserve.

## Ce qu’Oath peut affirmer en toute honnêteté

Oath repose sur une architecture de conservation différente : une application iPhone et iPad dont le code source est accessible, plutôt qu’un dispositif de signature matériel dédié. Le [dépôt public](https://github.com/devdasx/oath-wallet) expose le client mobile et les instructions de compilation sous licence MIT. Le [modèle de sécurité publié](https://oathwallet.org/data/security-model.json) indique que les secrets du portefeuille sont stockés par l’intermédiaire du trousseau iOS propre à l’application, avec une protection limitée à cet appareil, tandis que la base de données locale conserve des références opaques plutôt que des phrases de récupération ou des clés privées. Les transactions sont construites et signées sur l’appareil avant l’envoi des données signées à l’infrastructure réseau.

La [documentation d’Apple sur la sécurité de la plateforme](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) décrit la signature obligatoire du code, l’identification des développeurs, l’examen automatisé et humain de l’App Store, le cloisonnement applicatif et l’application des signatures à l’exécution. Sa [documentation relative au trousseau](https://support.apple.com/guide/security/secb0694df1a/1/web/1) décrit une protection propre à chaque élément et l’intervention de la Secure Enclave dans la gestion des clés du trousseau. Il s’agit de véritables contrôles de plateforme. Ils ne reviennent pas à affirmer que les clés privées de blockchain d’Oath sont elles-mêmes des clés de la Secure Enclave, et Oath ne formule pas cette affirmation.

Oath réduit aussi délibérément la surface fonctionnelle du produit. Elle ne propose ni compte conservé par un dépositaire ni copie de récupération détenue par l’entreprise, et sa conception centrale évite de transformer le portefeuille en comptoir d’achat et de vente, en moteur d’échange ou en navigateur intégré généraliste. La version 2.40.12 a ajouté des tests de santé de l’aléa physique pour repérer les répétitions extrêmes, la prédominance et les cycles prévisibles lorsque les utilisateurs produisent de l’entropie avec des dés, des lancers de pièce ou des chiffres. Ces contrôles peuvent détecter des motifs de défaillance manifestes ; ils ne peuvent prouver qu’un processus physique était équitable ou privé.

### Oath peut-il être plus sûr qu’un portefeuille matériel ?

Pour certains modèles de menace, oui. Comme affirmation universelle, non. Un portefeuille sur téléphone peut éviter le circuit de fabrication et d’expédition d’un appareil dédié, réduire le nombre d’objets signalant visiblement la conservation d’actifs de valeur, utiliser une plateforme dotée de mises à jour signées rapides et d’un cloisonnement mature, et présenter une implémentation inspectable dans une interface familière que les utilisateurs sont plus susceptibles d’employer correctement. Une surface fonctionnelle réduite peut également éliminer des catégories entières de risques liés au navigateur, aux échanges, aux autorisations et à la traduction entre appareils.

Pour d’autres modèles de menace, un dispositif de signature distinct et bien conçu constitue une frontière importante. Si le système d’exploitation du téléphone ou le processus du portefeuille est compromis, la séparation physique et un écran dont la fiabilité est indépendante peuvent empêcher un hôte connecté au réseau d’obtenir ou de détourner une clé. Pour des institutions ou des montants qui changeraient une vie, l’architecture la plus robuste peut être une politique multisignature soigneusement testée, reposant sur des implémentations indépendantes, une entropie indépendante, des lieux distincts et une récupération documentée — plutôt qu’un duel entre un téléphone et un boîtier matériel.

Le mot « matériel » ne devrait donc jamais clore l’analyse. Un iPhone est lui aussi du matériel. Les différences pertinentes concernent le code qui s’exécute, la manière dont il a été compilé et distribué, les endroits où les secrets sont accessibles, ce que l’utilisateur peut vérifier, la façon dont les transactions sont affichées, le déroulement des mises à jour et les défaillances uniques susceptibles de déplacer des fonds.

### La limite des éléments probants vaut aussi pour Oath

Le site web d’Oath affirme actuellement que l’application a fait l’objet d’un audit indépendant et qu’elle est compilée de façon reproductible. Son [registre public des audits](https://oathwallet.org/security) est désigné comme le lieu de référence pour les noms des auditeurs, le périmètre exact, les dates, les versions examinées, les rapports, les constats, les remédiations, les empreintes et les éléments de reproductibilité. Au moment de la publication, ce registre ne présentait pas encore ces artefacts concrets. Le dépôt GitHub public ne comportait pas non plus d’artefacts de publication permettant de reproduire indépendamment la correspondance avec un binaire de l’App Store.

Par conséquent, cet article n’affirme pas que « chaque ligne du binaire de l’App Store a été démontrée sûre », que plusieurs entreprises ont certifié chaque comportement, ni que l’IA a vérifié l’intégralité de l’application. De telles affirmations excéderaient les éléments probants accessibles au public. La distinction techniquement correcte est que le code source est publié sur GitHub, tandis qu’Apple distribue un binaire compilé et signé par l’intermédiaire de l’App Store. Relier les deux exige une recette de compilation publique, une révision immuable du code source, un verrouillage des dépendances, un artefact de l’App Store capturé, une procédure de normalisation des effets de la signature Apple, un résultat concordant et une attestation indépendante.

La vérification est la plus robuste lorsqu’une affirmation s’accompagne de suffisamment de preuves pour qu’un tiers sceptique puisse la reproduire. Oath doit être jugée selon cette norme avec autant de rigueur que tout fournisseur de portefeuilles matériels.

## Ce que doit contenir un dossier de vérification de niveau universitaire

Pour les chercheurs, les auditeurs, les journalistes et les évaluateurs institutionnels, une affirmation crédible sur la sécurité d’un portefeuille doit prendre la forme d’une chaîne d’éléments probants navigable, et non d’un mur de badges. Il convient, au minimum, d’exiger :

- 

Un modèle de menace précis. Nommez séparément la compromission à distance, l’extraction physique, les mises à jour malveillantes, la compromission du système de compilation, la faible entropie, la substitution de transaction, le vol de sauvegarde, la coercition et les problèmes de disponibilité.

- 

Une révision immuable soumise à examen. Indiquez le commit, le graphe des dépendances, les versions du compilateur et du SDK, les options de compilation, les droits et la configuration compris dans le périmètre.

- 

Un rapport indépendant dont l’auteur est identifié. Publiez le nom de l’auditeur, la méthodologie, les dates, les exclusions, les critères de gravité, les constats et les preuves utilisées pour clore chaque remédiation.

- 

La reproductibilité du code source au binaire. Fournissez une recette complète et les résultats de compilations indépendantes reliés à la version publique exacte. Expliquez toute différence non déterministe ou produite par la signature.

- 

Des preuves relatives au chemin d’entropie. Testez la source sur du matériel réel, vérifiez le comportement en cas de défaillance, rejetez tout repli silencieux et retracez le chemin exact employé par la version publiée. Des tests statistiques portant uniquement sur les sorties ne peuvent prouver que le générateur a été correctement raccordé.

- 

Des tests transactionnels adversariaux. Mettez à l’épreuve la substitution du destinataire, la manipulation des frais, les métadonnées hostiles, les limites de la signature aveugle, les diffusions interrompues et les divergences d’analyse entre chaque écran et chaque signataire.

- 

Des exercices de récupération et de mise à jour. Testez les instructions sous une contrainte temporelle réaliste, notamment en présence d’informations partielles, d’anciennes versions, d’une migration, d’appareils perdus et de la possibilité qu’une mise à jour ne puisse réparer les secrets existants.

- 

Une revue continue et diversifiée. Employez les tests déterministes, l’analyse statique, des spécialistes humains, le fuzzing, les tests sur appareils réels et la revue assistée par l’IA comme méthodes complémentaires. Consignez ce que chaque méthode a établi et ce qu’elle n’a pas établi.

## La menace peut sortir de l’écran

L’auto-conservation peut supprimer un dépositaire, mais elle peut également faire d’une personne l’ultime frontière d’autorisation. Un voleur incapable de briser la cryptographie peut s’en prendre au propriétaire, à sa famille, à son domicile, à son lieu de travail ou à son identité publique. Le matériel dédié peut parfois faciliter ce ciblage en signalant visiblement qu’une personne prend la conservation de ses actifs au sérieux, ou en créant un objet physique qu’un attaquant s’attend à trouver. Un téléphone peut lui aussi révéler les avoirs si les soldes sont visibles. Aucun de ces formats ne résout le problème de la coercition.

Une étude de 2024 évaluée par les pairs, [« Étude des attaques à la clé à molette : attaques physiques visant les utilisateurs de cryptomonnaies »](https://doi.org/10.4230/LIPIcs.AFT.2024.10), a analysé des entretiens, des forums et 146 articles de presse. Son jeu de données filtré issu de la presse comprenait 105 incidents d’attaque physique, dont 24 enlèvements et 6 meurtres recensés comme acte principal. Les auteurs soulignent la sous-déclaration et ont constaté que même des professionnels expérimentés de la sécurité n’étaient pas à l’abri. Ces chiffres décrivent le jeu de données de l’étude, non le taux d’incidence mondial, et ne prouvent pas davantage qu’un type particulier de portefeuille a causé chaque crime.

Le danger n’est pas théorique. En 2024, le [ministère de la Justice des États-Unis](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) a décrit des condamnations prononcées dans le cadre d’une conspiration ayant recouru à la surveillance, aux invasions de domicile, à l’enlèvement, aux agressions et aux menaces pour contraindre les victimes à vider des comptes de cryptomonnaies. La leçon n’est pas de céder à la panique ni de se détourner d’une aide légitime. Elle consiste à intégrer la confidentialité opérationnelle et la sécurité personnelle à la conception d’un portefeuille.

### La sécurité des personnes prime sur la récupération des actifs

- 

Ne divulguez ni vos soldes ni vos méthodes de stockage. Les adresses publiques, les captures d’écran, les conversations lors de conférences, les publications sur les réseaux sociaux, les dossiers d’expédition et les emballages jetés peuvent relier une identité, un lieu et une richesse supposée.

- 

Séparez les fonds courants des réserves. Un portefeuille de dépenses ne doit ni révéler ni contrôler l’intégralité des avoirs à long terme. Évitez de concentrer tous les actifs et tous les chemins de récupération derrière un seul secret immédiatement accessible.

- 

Recourez à une autorisation indépendante pour les montants importants. Un dispositif multisignature bien conçu peut empêcher qu’un appareil volé ou qu’une coercition exercée en un seul lieu suffise, mais uniquement si les clés, les implémentations et les supports de récupération sont véritablement séparés.

- 

Protégez ce que révèle l’interface. Utilisez le verrouillage de l’application et les contrôles de confidentialité du sélecteur d’applications, évitez d’afficher des soldes complets en public et vérifiez les destinataires sans exposer des avoirs sans rapport avec l’opération.

- 

Planifiez avec des professionnels locaux qualifiés. Les personnes et les institutions à haut risque devraient élaborer, avec des experts qui comprennent leur juridiction et leur situation personnelle, des procédures licites de sécurité physique, de déplacement, de réponse aux incidents, de succession et de protection familiale.

- 

Ne mettez jamais une vie en danger pour un portefeuille. Aucune phrase de récupération, aucun appareil, aucune transaction ni aucun montant ne justifie de subir une atteinte physique. Face à une menace immédiate, accordez la priorité à la sécurité des personnes et contactez les services d’urgence locaux dès que vous pouvez le faire sans danger.

## La leçon tient aux preuves, non à la loyauté de camp

La défaillance de Coldcard ne prouve pas que chaque Coldcard actuelle est dangereuse, que tous les portefeuilles matériels ne sont que du théâtre ou que tous les portefeuilles sur téléphone sont supérieurs. Coinkite a publié des versions corrigées, des consignes de migration, une validation indépendante ciblée et des limites explicites quant à ce que ces contrôles établissent. Une analyse responsable doit reconnaître à la fois la gravité de l’incident et la réalité des remédiations.

De même, Oath ne saurait hériter de la confiance au seul motif qu’elle critique une autre architecture. Son code source public, son modèle de conservation resserré, les contrôles de la plateforme Apple, la signature locale et son aptitude à être examinée ont une réelle portée. Ils gagnent en solidité lorsqu’un tiers identifié publie son périmètre et ses constats, lorsque des chercheurs peuvent reproduire le binaire distribué à partir d’un code source immuable, et lorsque la revue assistée par l’IA est associée à des tests déterministes et au jugement responsable d’êtres humains.

La conclusion durable est plus simple : la sécurité ne tient pas au matériau du boîtier ; elle tient à la qualité du secret, au comportement du système complet, à l’indépendance de ses défenses, à la clarté de son interface et aux preuves disponibles pour vérifier chaque affirmation importante. La complexité peut être nécessaire, mais elle doit justifier sa place, une menace maîtrisée à la fois.

Poursuivez votre lecture avec les guides d’Oath sur [la création d’entropie à partir d’un aléa physique](https://oathwallet.org/articles/build-wallet-with-dice-coin-flips-random-digits), [les phrases secrètes BIP39](https://oathwallet.org/articles/add-bip39-passphrase-oath-wallet), [le modèle de sécurité de l’auto-conservation](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model) et [le code d’accès de l’application et les contrôles de confidentialité](https://oathwallet.org/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy).

## Sources primaires et techniques

- 

[Coinkite : avis de sécurité Coldcard](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) — versions concernées, portée de l’entropie, versions corrigées et consignes de migration.

- 

[Coldcard : état actuel de la sécurité](https://coldcard.com/security/status) — versions actuelles, périmètre de la validation indépendante, limites et état du rapport post-mortem.

- 

[TRM Labs : analyse sur la chaîne du 5 août](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) — estimation datée des pertes et analyse des flux de transactions.

- 

[Kraken Security Labs : divulgation de l’injection de fautes visant Trezor](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) — extraction de la graine avec accès physique et atténuation par phrase secrète.

- 

[Ledger : rapport sur l’incident Connect Kit](https://www.ledger.com/blog/security-incident-report) — publication d’une dépendance malveillante et conséquences sur les signatures des utilisateurs.

- 

[Block : recherche sur une porte dérobée dans le micrologiciel](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) — exfiltration de secrets au moyen de signatures et mesures d’atténuation visant la chaîne d’approvisionnement.

- 

[Sécurité des plateformes Apple : sécurité des applications et signature du code](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) — distribution iOS, cloisonnement applicatif et contrôles d’intégrité à l’exécution.

- 

[Ordekian, Atondo-Siu, Hutchings et Vasek : étude sur les attaques à la clé à molette](https://doi.org/10.4230/LIPIcs.AFT.2024.10) — analyse de la sécurité physique évaluée par les pairs.

- 

[Ministère de la Justice des États-Unis : condamnations relatives à des invasions de domicile visant des cryptomonnaies](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) — coercition physique et surveillance documentées.

Oath n’entretient aucun lien d’affiliation avec Coldcard, Coinkite, Trezor, Kraken, Ledger, Block ou les chercheurs cités, et ne bénéficie de leur part d’aucune approbation. Les noms de produits et d’entreprises appartiennent à leurs propriétaires respectifs. Cet article a une visée pédagogique en matière de sécurité ; il ne constitue pas un conseil financier, juridique ou d’urgence personnalisé. Ne communiquez jamais une phrase de récupération, une clé privée, une phrase secrète de portefeuille, un code d’accès à l’application ou un mot de passe de sauvegarde à un site web, un agent d’assistance, un chercheur ou un assistant d’IA.
