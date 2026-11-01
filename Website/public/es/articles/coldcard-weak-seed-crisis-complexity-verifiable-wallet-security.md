# Crisis de las semillas débiles de Coldcard: complejidad no equivale a seguridad

Oath Research · September 3, 2026

https://oathwallet.org/es/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security

El incidente de Coldcard de 2026 no comprometió los dispositivos de forma remota. Reveló algo más fundamental: una carcasa sofisticada no puede proteger una semilla que era predecible desde su creación.

Nota de investigación, 3 de septiembre de 2026. Este artículo distingue entre hechos confirmados, afirmaciones del proveedor, estimaciones obtenidas de la cadena de bloques y nuestro propio análisis. El informe técnico formal posterior al incidente de Coinkite aún no se había publicado cuando se preparó este artículo. Los totales de pérdidas cambiaron a medida que los investigadores atribuyeron transacciones adicionales, por lo que las cifras que figuran a continuación son instantáneas fechadas, no un balance definitivo.

En julio de 2026, desaparecieron fondos en Bitcoin de miles de direcciones cuyos propietarios creían que sus claves estaban protegidas por carteras de hardware Coldcard. La primera corrección, y la más importante, es también la más reveladora: los dispositivos no fueron comprometidos de forma remota. Un error del firmware había debilitado la aleatoriedad empleada al crear algunas carteras. Los atacantes podían explorar en otro entorno el espacio de claves reducido, recuperar posibles claves privadas, comparar las direcciones derivadas con la cadena de bloques pública de Bitcoin y gastar los fondos coincidentes sin tocar el dispositivo físico.

Una cámara acorazada puede ser formidable en lo físico y, aun así, fallar si el secreto depositado en ella era predecible desde el principio.

Por eso este incidente importa mucho más allá de un solo proveedor. Cuestiona un atajo reconfortante: equiparar hardware con seguridad, más componentes con mayor protección y una larga lista de funciones con un alto grado de garantía. Ninguna de esas afirmaciones constituye un modelo de amenazas. La seguridad procede del sistema completo —entropía, firmware, hardware, proceso de compilación, distribución, interfaz, copias de seguridad, comportamiento del operador y seguridad física— y de pruebas que permitan a terceros someter sus afirmaciones a examen.

## Qué ocurrió con Coldcard

El [aviso oficial](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) de Coinkite afirma que el firmware afectado utilizaba una ruta defectuosa para generar semillas. Las semillas de carteras creadas con firmware 4.0.1 a 4.1.9 en dispositivos Mk2 o Mk3 estaban en riesgo, salvo que se hubiera añadido suficiente entropía privada e independiente procedente de dados o que una frase de contraseña BIP39 sólida y única hubiese creado una barrera adicional. El aviso también abarca las semillas generadas en dispositivos Mk4, Mk5 y Q antes de sus versiones corregidas, tanto estándar como Edge. Para esos dispositivos posteriores, Coinkite informó de unos 72 bits de entropía, en lugar de los 128 bits previstos.

El fallo se originó en un firmware publicado en marzo de 2021 y permaneció latente durante años. La protección del hardware funcionó sobre el secreto que recibió; el problema era que el proceso de generación del secreto no aportaba la incertidumbre esperada. Una vez que un atacante podía enumerar semillas plausibles a un coste viable, la cadena de bloques pública ofrecía una prueba de pertenencia perfecta: derivar direcciones, buscar saldos y firmar con cualquier clave recuperada. No hacía falta ningún mensaje de phishing, sesión USB, paquete robado ni acceso físico.

### Por qué una entropía débil es catastrófica

La semilla de una cartera no es segura porque a una persona le parezca aleatoria. Es segura cuando ningún adversario puede distinguir ni enumerar de forma viable las posibilidades subyacentes. Cada bit de entropía duplica el espacio de búsqueda. Pasar de 128 bits a 72 bits no vuelve la semilla «un poco más débil»: elimina 56 duplicaciones sucesivas del trabajo. Un espacio de búsqueda efectivo aún menor convierte una búsqueda astronómicamente imposible en un proyecto de ingeniería.

Las palabras de recuperación siguen siendo sintácticamente válidas. Las direcciones parecen normales. El dispositivo firma con normalidad. Las copias de seguridad se restauran correctamente. Es un fallo silencioso: todos los rituales visibles pueden completarse con éxito cuando la premisa de seguridad ya se ha derrumbado. Precisamente por eso la generación de números aleatorios necesita pruebas deterministas de su interconexión, instrumentación en dispositivos reales en torno a la fuente de entropía y pruebas de publicación que vinculen el código fuente revisado con el firmware distribuido.

### El robo se desarrolló en oleadas

El 30 de julio, el primer barrido comunicado movió aproximadamente 594 BTC desde unas 500 direcciones en cerca de 25 minutos. Las atribuciones posteriores ampliaron el alcance del incidente. Una [evaluación de TRM Labs publicada el 5 de agosto](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) describió un recuento provisional cercano a 1.816 BTC —unos USD 116 millones en ese momento— procedentes de más de 5.200 direcciones y distribuidos en cuatro oleadas. Otros investigadores aplicaron reglas de confirmación distintas y posteriormente comunicaron totales algo diferentes. Por tanto, estas cifras deben interpretarse como prueba de la magnitud, no como un registro contable definitivo.

La [página actual sobre el estado de la seguridad](https://coldcard.com/security/status) de Coinkite indica expresamente que el informe formal posterior al incidente sigue en curso y no afirma que todas las pérdidas comunicadas hayan sido atribuidas de manera individual. Esa incertidumbre no es motivo para restar importancia al incidente. Es motivo para preservar la diferencia entre el mecanismo verificado, las transacciones observadas, la atribución analítica y la conclusión forense definitiva.

## Actualizar el firmware no repara una semilla antigua

Este es el hecho operativo que los usuarios afectados no pueden pasar por alto. El firmware corregido subsana la generación futura de semillas; no puede añadir entropía con carácter retroactivo a una semilla que ya existe. Una cartera restaurada a partir de esa semilla en un dispositivo nuevo sigue bajo el control del mismo secreto vulnerable. Sustituir la carcasa metálica, instalar una aplicación móvil o trasladar las palabras a otra marca no cambia la clave. Los fondos deben transferirse a direcciones derivadas de una semilla recién generada y protegida de forma independiente.

Según lo verificado el 3 de septiembre de 2026, la página de estado de Coldcard indicaba como versiones estándar recomendadas la 5.6.1 para Mk4/Mk5 y la 1.5.1Q para Q. Las versiones mínimas corregidas eran: 4.2.0 o posterior para Mk2/Mk3; 5.6.0 o posterior para Mk4/Mk5 estándar; 1.5.0Q o posterior para Q estándar; 6.6.0X o posterior para Mk4/Mk5 Edge; y 6.6.0QX o posterior para Q Edge. Las ramas de publicación importan: una versión Edge con un número superior no equivale automáticamente a una versión estándar corregida.

### Si es posible que esté afectado

- 

Deje de confiar en la carcasa. Determine el modelo, la rama de publicación, el firmware que se utilizó al generar la semilla y si se aplica claramente la excepción oficial relativa a dados independientes. Si tiene dudas, considere afectada la semilla.

- 

Siga únicamente las instrucciones oficiales. Abra directamente el aviso de Coldcard y la página sobre el estado de la seguridad, verifique el firmware firmado y los hashes publicados, y rechace toda «ayuda para la migración» no solicitada. Ningún asistente legítimo necesita su frase de recuperación.

- 

Cree una semilla completamente nueva en un entorno corregido. No edite, reordene ni añada palabras a la frase antigua. Una cartera nueva necesita entropía nueva. Si el saldo es considerable, contemple una implementación independiente o una política multifirma bien diseñada, para que la ruta de generación de semillas de un único proveedor no sea la única raíz de confianza.

- 

Verifique la recuperación antes de depositar fondos. Registre la copia de seguridad en privado, recupérela mediante un proceso controlado y confirme la huella digital pública o la dirección de recepción esperadas. Una copia de seguridad que nunca se ha probado no deja de ser una suposición.

- 

Transfiera primero una pequeña cantidad de prueba y, después, el resto. Verifique el destino y la confirmación antes de transferir el saldo completo. Evite improvisar con prisas, pero no confunda un procedimiento sereno con permiso para demorar la migración de una semilla expuesta.

- 

Retire la semilla antigua. Una actualización de firmware y una frase de contraseña sólida añadida con posterioridad no la reparan. Conserve los registros necesarios a efectos fiscales o legales sin mantener copias innecesarias del secreto.

Coinkite afirma que al menos 50 tiradas de dados justas, independientes y privadas, realizadas en el flujo Add Dice Rolls afectado, aportaban por sí solas un mínimo de 128 bits; 99 tiradas o más aportaban unos 256 bits. Las condiciones exactas importan. Si la secuencia se registró, fue observada, estaba sesgada, no era independiente o suscita dudas, no deduzca seguridad del mero recuento. Una frase de contraseña BIP39 sólida y preexistente puede añadir una barrera, pero Coinkite sigue recomendando migrar y no sostiene que una frase de contraseña repare la semilla.

## El dispositivo no fue hackeado, y esa es la advertencia más profunda

Llamar «hackeo de una cartera de hardware» a toda pérdida comprime varias clases de fallo distintas en una sola frase efectista. Eso oculta los controles que podrían haber ayudado. En el incidente de Coldcard, el atacante no vulneró la carcasa, el teclado, los controles USB ni el elemento seguro que poseía cada víctima. El atacante eludió el dispositivo porque el secreto raíz podía enumerarse.

Un límite de seguridad solo protege aquello que lo atraviesa. Si la clave que entra en un elemento seguro es débil, si un firmware malicioso la filtra mediante las firmas, si la pantalla muestra un destino controlado por el atacante o si se coacciona a una persona para que autorice una transferencia, la existencia de hardware dedicado no neutraliza el ataque.

## Las pérdidas de las carteras de hardware no son todas iguales

Varios incidentes documentados y demostraciones de investigación muestran por qué esta categoría exige precisión. No demuestran que las carteras de hardware sean inútiles. Muestran que el hardware traslada el riesgo a otro sistema compuesto por chips, firmware, cadenas de suministro, software anfitrión, protocolos de firma, copias de seguridad y procedimientos humanos.

### 1. Inyección de fallos y extracción física de la semilla

En 2020, [Kraken Security Labs divulgó](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) una técnica de alteración del voltaje contra los dispositivos Trezor One y Model T. Kraken informó de que unos 15 minutos de acceso físico podían permitir extraer material cifrado de la semilla y de que, después, podía aplicarse fuerza bruta a un PIN corto. Su mitigación práctica consistía en una frase de contraseña BIP39 sólida que no estuviera almacenada en el dispositivo. Kraken documentó una clase de ataque similar contra KeepKey.

Esta amenaza es distinta de la de Coldcard. Requiere poseer el dispositivo objetivo y aplicar inyección de fallos propia de un laboratorio. Demuestra que la resistencia a manipulaciones depende del microcontrolador elegido y del diseño del almacenamiento, y que un PIN no constituye necesariamente un secreto de cifrado con alta entropía.

### 2. Software comprometido en torno a un firmante físico legítimo

En diciembre de 2023, el [incidente de la cadena de suministro de Ledger Connect Kit](https://www.ledger.com/blog/security-incident-report) introdujo código malicioso en dApps que cargaban un paquete comprometido. Según Ledger, el código engañó a usuarios de EVM para que firmaran transacciones que vaciaban sus fondos. Los dispositivos físicos no revelaron espontáneamente sus semillas; el sistema que los rodeaba presentó intenciones maliciosas a firmantes legítimos.

Esta clase de fallo explica por qué «la clave nunca salió del dispositivo» es una condición necesaria, pero insuficiente. Una clave segura puede autorizar fielmente una transacción equivocada cuando el usuario, el sistema anfitrión o la pantalla no pueden comprender de forma fiable qué se está firmando. La decodificación clara de las transacciones, las pantallas fiables, los permisos restringidos, los controles de dependencias y la resistencia a la firma ciega forman parte de la seguridad de la custodia.

### 3. Firmware malicioso que filtra secretos mediante firmas normales

Investigadores de Block han [publicado un ataque práctico de investigación](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) en el que el firmware comprometido de una cartera codifica de manera encubierta material secreto dentro de firmas aparentemente normales. Su modelo de amenazas presupone que el firmware se ve comprometido por vías como una intrusión en la cadena de suministro, la actuación de una persona con acceso interno, el compromiso del sistema de compilación o el de una clave de firma. El aislamiento físico no ayuda si la propia transacción firmada se convierte en el canal de exfiltración.

Aquí es donde cobran sentido las compilaciones reproducibles, varios equipos de compilación independientes, las dependencias fijadas, el arranque seguro y la diversidad en la multifirma. Abordan eslabones concretos de una cadena. No certifican por arte de magia el diseño, el código fuente ni al operador.

### 4. Exposición de copias de seguridad, sustitución de direcciones y coacción

Muchos robos reales nunca explotan el silicio. Los atacantes sustraen o fotografían copias de seguridad de semillas, sustituyen una dirección de recepción, suplantan al servicio de asistencia, comprometen un proceso de compra o envío, obtienen un dispositivo junto con un PIN débil u obligan al propietario a cooperar. Por diseño, la frase de recuperación sigue siendo una credencial maestra portátil: cualquiera que la obtenga puede restaurar la cartera en otro lugar, sin importar dónde esté el dispositivo original.

## Por qué una mayor complejidad puede empeorar la seguridad

La complejidad está justificada en ocasiones. Una pantalla independiente puede hacer más fiable la revisión de una transacción. Un elemento seguro puede elevar el coste de la extracción física. La multifirma puede eliminar una única clave como punto de fallo. Pero cada mecanismo añadido también crea interfaces, estados, vías de actualización, dependencias, procedimientos de recuperación y supuestos. La pregunta correcta no es «¿Es complejo?», sino «¿Qué amenaza controla cada componente y qué nuevos modos de fallo introduce?».

El principio clásico de Saltzer y Schroeder de [economía de mecanismos](https://www.ojp.gov/ncjrs/virtual-library/abstracts/protection-information-computer-systems) establece que los diseños de protección deben ser tan simples y pequeños como sea posible, para que su inspección y comprensión sigan siendo viables. La moderna [guía del NIST sobre seguridad de sistemas](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-160v2r1.pdf) también trata como cuestiones arquitectónicas tanto la reducción de la superficie de ataque como los componentes multifunción grandes y difíciles de analizar. La simplicidad no es ausencia de controles. Es negarse a añadir controles cuyo comportamiento no pueda explicarse, probarse y operarse correctamente.

- 

Más código crea más defectos posibles. También encarece una revisión completa y dificulta el razonamiento sobre las interacciones.

- 

Más modos crean riesgos de configuración. El firmware estándar frente al Edge, los múltiples flujos de generación de semillas, las carteras con frase de contraseña, las rutas USB y aisladas físicamente, y las variantes de copias de seguridad pueden ser seguros por separado y, sin embargo, resultar confusos al combinarse.

- 

Más interfaces crean riesgos de interpretación. Una pantalla física, una aplicación anfitriona, un formato QR, un flujo con microSD, un conector del navegador y un servicio de red deben coincidir exactamente en aquello que el usuario está autorizando.

- 

Más rituales pueden reducir el cumplimiento. Si la vía segura es difícil, las personas omiten comprobaciones, posponen actualizaciones, reutilizan copias de seguridad o siguen instrucciones de emergencia sin comprenderlas.

- 

Una mayor confianza puede amplificar la pérdida. Un producto comercializado como «en frío», «aislado» o «imposible de hackear» puede inducir al usuario a concentrar más valor tras una única semilla. La concentración convierte un solo defecto oculto en un desenlace catastrófico.

La defensa en profundidad es valiosa cuando las capas son independientes. Repetir la misma implementación, la misma fuente de entropía, el mismo proveedor o el mismo secreto de recuperación no constituye una defensa independiente.

## Código abierto, auditorías, compilaciones reproducibles y revisión mediante IA no son sinónimos

El historial de Coldcard resulta especialmente instructivo porque su firmware era público y existía documentación sobre compilaciones reproducibles, mientras la ruta vulnerable permanecía durante años en las versiones publicadas. Esto no vuelve inútil la apertura. Muestra que disponer de pruebas y examinar realmente la propiedad correcta son cosas distintas.

- 

Código abierto significa que terceros pueden inspeccionar la implementación. No demuestra que alguien haya revisado todas las rutas críticas para la seguridad ni que el árbol público haya producido el binario instalado.

- 

Una auditoría independiente es un trabajo acotado. Su valor depende del revisor identificado, el commit o la versión exactos, el modelo de amenazas, las propiedades comprobadas, las exclusiones, los hallazgos y las pruebas de subsanación. «Auditado» sin alcance no es más que un eslogan.

- 

Una compilación reproducible permite que compiladores independientes sigan una receta publicada y comparen los resultados. Una coincidencia puede vincular el código fuente con un artefacto de publicación; no demuestra que el código fuente sea correcto.

- 

La revisión de la App Store y la firma de código establecen controles de distribución y de plataforma. Por sí solas no demuestran que un binario de la App Store sea idéntico bit a bit a un repositorio público.

- 

La revisión asistida por IA puede examinar grandes bases de código, generar hipótesis adversarias, comparar invariantes y acelerar el análisis humano. Un modelo también puede pasar por alto el contexto, aceptar una premisa falsa o producir un hallazgo verosímil pero incorrecto. La revisión mediante IA es otra perspectiva, no una autoridad de certificación.

La página actual sobre el estado de la seguridad de Coldcard ofrece un buen modelo para expresar el alcance: menciona instrumentación dirigida del generador de números aleatorios en dispositivos reales, revisiones del código fuente, la revisión de una corrección urgente, y una compilación reproducible junto con el seguimiento de la ruta de los dados; después afirma de forma expresa que esas comprobaciones no constituyen una auditoría completa de todos los binarios de firmware ni garantizan la ausencia de defectos. Esa frase vale más que un distintivo sin matices.

## Qué puede afirmar Oath con honestidad

Oath se basa en una arquitectura de custodia diferente: una aplicación para iPhone y iPad cuyo código fuente está disponible, en lugar de un firmante físico dedicado. El [repositorio público](https://github.com/devdasx/oath-wallet) expone el cliente móvil y las instrucciones de compilación bajo la licencia MIT. El [modelo de seguridad publicado](https://oathwallet.org/data/security-model.json) indica que los secretos de la cartera se almacenan mediante el llavero de iOS dentro del ámbito de la aplicación y con protección exclusiva para ese dispositivo, mientras que la base de datos local conserva referencias opacas en vez de frases de recuperación o claves privadas. Las transacciones se construyen y firman en el dispositivo antes de enviar los datos firmados a la infraestructura de red.

La [documentación de Apple sobre seguridad de la plataforma](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) describe la firma de código obligatoria, los desarrolladores identificados, la revisión automatizada y humana de la App Store, el aislamiento de procesos y la aplicación de firmas en tiempo de ejecución. Su [documentación sobre el llavero](https://support.apple.com/guide/security/secb0694df1a/1/web/1) describe la protección por elemento y la intervención del Secure Enclave en la gestión de claves del llavero. Son controles reales de la plataforma. No equivalen a afirmar que las propias claves privadas de blockchain de Oath sean claves del Secure Enclave, y Oath no lo afirma.

### ¿Puede Oath ser más segura que una cartera de hardware?

Para algunos modelos de amenazas, sí. Como afirmación universal, no. Una cartera móvil puede evitar la cadena de fabricación y envío de un dispositivo dedicado, reducir el número de objetos que revelan a simple vista la custodia de activos valiosos, utilizar una plataforma con actualizaciones firmadas rápidas y un aislamiento maduro, y ofrecer una implementación inspeccionable mediante una interfaz familiar que los usuarios tienen más probabilidades de utilizar correctamente. Una superficie funcional más reducida también puede eliminar categorías enteras de riesgo ligadas al navegador, los intercambios, las autorizaciones y la interpretación entre dispositivos.

Para otros modelos de amenazas, un firmante independiente y bien diseñado constituye un límite importante. Si el sistema operativo del teléfono o el proceso de la cartera están comprometidos, la separación física y una pantalla independiente fiable pueden impedir que un sistema anfitrión conectado a la red obtenga o utilice indebidamente una clave. Para una institución o cuando está en juego un patrimonio capaz de cambiar una vida, la arquitectura más sólida puede ser una política multifirma cuidadosamente probada, con implementaciones independientes, entropía independiente, ubicaciones separadas y una recuperación documentada; no una competición entre un teléfono y una caja física.

Por tanto, la palabra «hardware» nunca debe poner fin al análisis. Un iPhone también es hardware. Las diferencias pertinentes son qué código se ejecuta, cómo se compiló y distribuyó, dónde están disponibles los secretos, qué puede verificar el usuario, cómo se muestran las transacciones, cómo se realizan las actualizaciones y qué fallos individuales pueden mover los fondos.

### El límite de las pruebas también importa para Oath

El sitio web de Oath afirma actualmente que la aplicación ha sido auditada de forma independiente y que su compilación es reproducible. Su [registro público de auditorías](https://oathwallet.org/security) se ha designado como el lugar canónico para los nombres de los revisores, el alcance exacto, las fechas, las versiones revisadas, los informes, los hallazgos, las subsanaciones, los hashes y el material de reproducibilidad. En el momento de la publicación, ese registro aún no mostraba esos artefactos concretos. El repositorio público de GitHub tampoco contenía artefactos de publicación con los que pudiera reproducirse de forma independiente la correspondencia con un binario de la App Store.

Por consiguiente, este artículo no afirma que «se haya demostrado que todas las líneas del binario de la App Store son seguras», que varias empresas hayan certificado todos los comportamientos ni que la IA haya verificado la aplicación completa. Esas afirmaciones excederían las pruebas públicas disponibles. La distinción técnicamente correcta es que el código fuente está publicado en GitHub, mientras Apple distribuye un binario compilado y firmado a través de la App Store. Vincular ambos exige una receta pública de compilación, una revisión inmutable del código fuente, un bloqueo de dependencias, un artefacto capturado de la App Store, un procedimiento para normalizar los efectos de la firma de Apple, un resultado coincidente y una atestación independiente.

La verificación alcanza su máxima solidez cuando una afirmación incluye pruebas suficientes para que un tercero escéptico pueda reproducirla. Oath debe juzgarse con ese criterio y con la misma firmeza que cualquier proveedor de carteras de hardware.

## Qué debe contener un paquete de verificación de nivel universitario

Para investigadores, auditores, periodistas y evaluadores institucionales, una afirmación creíble sobre la seguridad de una cartera debe constituir una cadena de pruebas navegable, no un muro de distintivos. Como mínimo, debe exigirse:

- 

Un modelo de amenazas preciso. Distinga por separado el compromiso remoto, la extracción física, las actualizaciones maliciosas, el compromiso del sistema de compilación, la entropía débil, la sustitución de transacciones, el robo de copias de seguridad, la coacción y la disponibilidad.

- 

Una revisión inmutable del código que se examinó. Identifique el commit, el grafo de dependencias, las versiones del compilador y del SDK, las opciones de compilación, los entitlements y la configuración incluidos en el alcance.

- 

Un informe independiente con autor identificado. Publique el revisor, la metodología, las fechas, las exclusiones, los criterios de gravedad, los hallazgos y las pruebas utilizadas para dar por subsanado cada uno.

- 

Reproducibilidad del código fuente al binario. Proporcione una receta completa y resultados de compilaciones independientes vinculados a la versión pública exacta. Explique cualquier diferencia no determinista o generada por la firma.

- 

Pruebas de la ruta de entropía. Pruebe la fuente en hardware real, verifique el comportamiento ante fallos, rechace las alternativas silenciosas y rastree la ruta exacta utilizada por la compilación publicada. Las pruebas estadísticas de resultados, por sí solas, no pueden demostrar que el generador estuviera conectado correctamente.

- 

Pruebas adversarias de transacciones. Ponga a prueba la sustitución de destinatarios, la manipulación de comisiones, los metadatos hostiles, los límites de la firma ciega, las transmisiones interrumpidas y las discrepancias entre los analizadores de cada pantalla y cada firmante.

- 

Simulacros de recuperación y actualización. Pruebe las instrucciones bajo una presión de tiempo realista, incluida la información parcial, las versiones antiguas, la migración, los dispositivos perdidos y la posibilidad de que una actualización no pueda reparar secretos ya existentes.

- 

Revisión continua y diversa. Utilice como métodos complementarios pruebas deterministas, análisis estático, especialistas humanos, fuzzing, pruebas en dispositivos reales y revisión asistida por IA. Deje constancia de lo que cada método demostró y de lo que no demostró.

## La amenaza puede salir de la pantalla

La autocustodia puede eliminar al custodio, pero también puede convertir a una persona en la última barrera de autorización. Un ladrón incapaz de quebrar la criptografía puede optar por atacar al propietario, su familia, su domicilio, su lugar de trabajo o su identidad pública. En ocasiones, el hardware dedicado puede facilitar ese señalamiento al revelar de forma visible que una persona se toma en serio la custodia o al crear un objeto físico que el atacante espera encontrar. Un teléfono también puede revelar los activos si los saldos son visibles. Ninguno de los dos formatos resuelve la coacción.

Un estudio de 2024 revisado por pares, [«Investigación de los ataques con llave inglesa: ataques físicos dirigidos a usuarios de criptomonedas»](https://doi.org/10.4230/LIPIcs.AFT.2024.10), analizó entrevistas, foros y 146 artículos de prensa. Su conjunto filtrado de noticias contenía 105 incidentes de ataques físicos, incluidos 24 secuestros y 6 asesinatos consignados como acto principal. Los autores subrayan la infranotificación y constataron que ni siquiera los profesionales experimentados en seguridad eran inmunes. Estas cifras describen el conjunto de datos del estudio, no la tasa de incidencia mundial, y tampoco demuestran que un tipo concreto de cartera causara cada delito.

El peligro no es teórico. En 2024, el [Departamento de Justicia de Estados Unidos](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) describió condenas por una conspiración que recurrió a vigilancia, allanamientos de morada, secuestros, agresiones y amenazas para obligar a las víctimas a vaciar cuentas de criptomonedas. La lección no es caer en el pánico ni rehuir la ayuda legítima. Es tratar la privacidad operativa y la seguridad personal como parte del diseño de una cartera.

### La seguridad humana está por encima de la recuperación de activos

- 

No divulgue saldos ni detalles de almacenamiento. Las direcciones públicas, las capturas de pantalla, las conversaciones en congresos, las publicaciones en redes sociales, los registros de envío y los embalajes desechados pueden vincular identidad, ubicación y patrimonio aparente.

- 

Separe los fondos cotidianos de las reservas. Una cartera para gastos no debe revelar ni controlar la totalidad del patrimonio a largo plazo. Evite concentrar todos los activos y todas las vías de recuperación detrás de un único secreto accesible de inmediato.

- 

Utilice una autorización independiente para valores considerables. Una multifirma bien diseñada puede impedir que baste con un dispositivo robado o con coaccionar a una persona en un solo lugar, pero únicamente cuando las claves, las implementaciones y los materiales de recuperación estén realmente separados.

- 

Proteja lo que revela la interfaz. Utilice el bloqueo de la aplicación y los controles de privacidad del selector de aplicaciones, evite mostrar saldos completos en público y verifique a los destinatarios sin exponer activos ajenos a la operación.

- 

Planifique con profesionales locales cualificados. Las personas e instituciones de alto riesgo deben elaborar procedimientos lícitos de seguridad física, viajes, respuesta a incidentes, sucesiones y seguridad familiar con expertos que conozcan su jurisdicción y sus circunstancias personales.

- 

Nunca arriesgue una vida por una cartera. Ninguna frase de recuperación, dispositivo, transacción o cantidad justifica sufrir daños físicos. Ante una amenaza inmediata, dé prioridad a la seguridad de las personas y póngase en contacto con los servicios locales de emergencia cuando sea seguro hacerlo.

## La lección son las pruebas, no la lealtad tribal

El fallo de Coldcard no demuestra que todos los dispositivos Coldcard actuales sean inseguros, que toda cartera de hardware sea mero teatro ni que toda cartera móvil sea superior. Coinkite ha publicado versiones corregidas, instrucciones de migración, validaciones independientes dirigidas y límites explícitos sobre lo que demuestran esas comprobaciones. Un análisis responsable debe reconocer tanto la gravedad del incidente como el historial de subsanación.

Del mismo modo, Oath no debe merecer confianza solo por criticar otra arquitectura. Son significativos su código fuente público, su modelo de custodia limitado, los controles de la plataforma Apple, la firma local y su posibilidad de revisión. Se fortalecen cuando un tercero identificado publica el alcance y los hallazgos, cuando los investigadores pueden reproducir el binario distribuido a partir de código fuente inmutable y cuando la revisión asistida por IA se combina con pruebas deterministas y un criterio humano responsable.

La conclusión perdurable es más sencilla: la seguridad no reside en el material de la caja, sino en la calidad del secreto, el comportamiento del sistema completo, la independencia de sus defensas, la claridad de su interfaz y las pruebas disponibles para verificar cada afirmación importante. La complejidad puede ser necesaria, pero debe ganarse su lugar controlando una amenaza concreta cada vez.

Continúe con las guías de Oath sobre [Create your first wallet](https://help.oathwallet.org/articles/create-wallet), [frases de contraseña BIP39](https://oathwallet.org/articles/add-bip39-passphrase-oath-wallet), [el modelo de seguridad de la autocustodia](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model), y [los controles de código de acceso y privacidad de la aplicación](https://oathwallet.org/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy).

## Fuentes primarias y técnicas

- 

[Coinkite: aviso de seguridad de Coldcard](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) — versiones afectadas, alcance de la entropía, versiones corregidas e instrucciones de migración.

- 

[Coldcard: estado actual de la seguridad](https://coldcard.com/security/status) — versiones actuales, alcance de la validación independiente, limitaciones y estado del informe posterior al incidente.

- 

[TRM Labs: evaluación on-chain del 5 de agosto](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) — estimación de pérdidas fechada y análisis del flujo de transacciones.

- 

[Kraken Security Labs: divulgación de la inyección de fallos en Trezor](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) — extracción de semillas mediante acceso físico y mitigación con una frase de contraseña.

- 

[Ledger: informe sobre el incidente de Connect Kit](https://www.ledger.com/blog/security-incident-report) — publicación de una dependencia maliciosa e impacto en las firmas de los usuarios.

- 

[Block: investigación sobre una puerta trasera en el firmware](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) — exfiltración de secretos mediante firmas y mitigaciones en la cadena de suministro.

- 

[Seguridad de las plataformas Apple: seguridad de aplicaciones y firma de código](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) — distribución en iOS, aislamiento de procesos y controles de integridad en tiempo de ejecución.

- 

[Ordekian, Atondo-Siu, Hutchings y Vasek: estudio sobre ataques con llave inglesa](https://doi.org/10.4230/LIPIcs.AFT.2024.10) — análisis de seguridad física revisado por pares.

- 

[Departamento de Justicia de Estados Unidos: condenas por allanamientos de morada para robar criptomonedas](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) — coacción física y vigilancia documentadas.

Oath no está afiliada a Coldcard, Coinkite, Trezor, Kraken, Ledger, Block ni a los investigadores citados, ni cuenta con su respaldo. Los nombres de productos y empresas pertenecen a sus respectivos propietarios. Este artículo ofrece formación sobre seguridad, no asesoramiento financiero, jurídico ni de emergencia personalizado. Nunca facilite una frase de recuperación, una clave privada, una frase de contraseña de la cartera, un código de acceso de la aplicación o una contraseña de copia de seguridad a un sitio web, un agente de asistencia, un investigador o un asistente de IA.
