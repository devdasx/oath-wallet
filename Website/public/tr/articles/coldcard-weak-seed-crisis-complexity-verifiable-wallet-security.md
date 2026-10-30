# Coldcard’ın Zayıf Tohum Krizi: Karmaşıklık Güvenlikle Aynı Şey Değildir

Oath Research · September 3, 2026

https://oathwallet.org/tr/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security

2026’daki Coldcard vakasında cihazlar uzaktan ele geçirilmedi. Vaka, daha temel bir gerçeği açığa çıkardı: Gelişmiş bir muhafaza, oluşturulduğu anda öngörülebilir olan bir tohumu koruyamaz.

Araştırma notu, 3 Eylül 2026. Bu makale; doğrulanmış olguları, sağlayıcı açıklamalarını, zincir üstü tahminleri ve kendi analizimizi birbirinden ayırır. Bu makale hazırlanırken Coinkite’ın resmî teknik olay sonrası inceleme raporu henüz yayımlanmamıştı. Araştırmacılar ek işlemleri vakayla ilişkilendirdikçe toplam kayıp tutarı değiştiğinden, aşağıdaki rakamlar nihai bir bilanço değil, belirli tarihlere ait anlık görüntülerdir.

Temmuz 2026’da, anahtarlarının Coldcard donanım cüzdanlarıyla korunduğuna inanan kişilere ait binlerce adresteki Bitcoin kayboldu. İlk ve en önemli düzeltme, aynı zamanda en açıklayıcı olanıdır: cihazlar uzaktan ele geçirilmedi. Bir ürün yazılımı hatası, bazı cüzdanlar oluşturulurken kullanılan rastgeleliği zayıflatmıştı. Saldırganlar daralmış anahtar uzayını başka bir yerde tarayabiliyor, olası özel anahtarları elde edebiliyor, bunlardan türetilen adresleri herkese açık Bitcoin blok zinciriyle karşılaştırabiliyor ve donanıma dokunmadan eşleşen fonları harcayabiliyordu.

Bir kasa fiziksel açıdan son derece dayanıklı olabilir; ancak içine konan sır en başından öngörülebilir durumdaysa yine de başarısız olur.

Bu nedenle bu vaka tek bir sağlayıcının çok ötesinde önem taşır. Rahatlatıcı bir kestirme varsayıma meydan okur: donanım güvenlik demektir, daha fazla bileşen daha fazla koruma demektir ve uzun bir özellik listesi yüksek güvence demektir. Bu önermelerin hiçbiri bir tehdit modeli değildir. Güvenlik; entropi, ürün yazılımı, donanım, derleme süreci, dağıtım, arayüz, yedekler, operatör davranışı ve fiziksel güvenliği kapsayan sistemin bütününden ve dışarıdakilerin sistemin iddialarını sınamasına olanak veren kanıtlardan doğar.

## Coldcard’a ne oldu?

Coinkite’ın [resmî duyurusu](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/), etkilenen ürün yazılımının hatalı bir tohum oluşturma yolu kullandığını belirtiyor. Mk2 veya Mk3 cihazlarında 4.0.1 ile 4.1.9 arasındaki ürün yazılımı sürümleriyle oluşturulan cüzdan tohumları; yeterli miktarda özel ve bağımsız zar entropisi eklenmediği ya da güçlü ve benzersiz bir BIP39 parola ifadesi ek bir engel oluşturmadığı sürece risk altındaydı. Duyuru, düzeltilmiş standart veya Edge sürümlerinden önce Mk4, Mk5 ve Q cihazlarında oluşturulan tohumları da kapsıyor. Coinkite, bu sonraki cihazlarda amaçlanan 128 bit yerine yaklaşık 72 bit entropi bulunduğunu bildirdi.

Sorun, Mart 2021’de yayımlanan ürün yazılımında ortaya çıktı ve yıllarca gizli kaldı. Donanım koruması, kendisine verilen sır üzerinde çalışıyordu; sorun, sır oluşturma sürecinin beklenen belirsizliği sağlamamasıydı. Saldırgan makul maliyetle olası tohumları sıralayabildiği anda, herkese açık blok zinciri kusursuz bir üyelik testi sundu: adresleri türet, değer olup olmadığına bak ve ele geçirilen herhangi bir anahtarla imzala. Kimlik avı istemi, USB oturumu, çalınmış paket veya fiziksel erişim gerekmiyordu.

### Zayıf entropi neden yıkıcıdır?

Bir cüzdan tohumu insana rastgele göründüğü için güvenli değildir. Altta yatan olasılıklar hiçbir saldırgan tarafından uygulanabilir koşullarda ayırt edilemediğinde veya sıralanamadığında güvenlidir. Entropinin her biti arama uzayını iki katına çıkarır. 128 bitten 72 bite düşmek tohumu “biraz daha zayıf” kılmaz; yapılması gereken işi 56 kez ikiye katlama düzeyinde azaltır. Daha da küçük bir etkin arama uzayı, astronomik ölçüde olanaksız bir aramayı bir mühendislik projesine dönüştürür.

Kurtarma sözcükleri sözdizimsel olarak geçerliliğini korur. Adresler olağan görünür. Donanım normal biçimde imzalar. Yedekler doğru biçimde geri yüklenir. Bu sessiz bir arızadır: güvenliğin temel varsayımı çoktan çökmüşken görünür ritüellerin tümü başarıyla tamamlanabilir. Rastgele sayı üretecinin bağlantılarının belirlenimci testlerle sınanmasına, entropi kaynağının gerçek cihazlarda ölçümlenmesine ve incelenen kaynak kodu sevk edilen ürün yazılımına bağlayan sürüm kanıtlarına ihtiyaç duyulmasının nedeni tam da budur.

### Hırsızlık dalgalar hâlinde gerçekleşti

30 Temmuz’da bildirilen ilk toplu aktarım, yaklaşık 25 dakika içinde yaklaşık 500 adresten kabaca 594 BTC aktardı. Daha sonraki ilişkilendirmeler olayın kapsamını genişletti. [TRM Labs’in 5 Ağustos’ta yayımladığı değerlendirme](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack), dört dalga boyunca 5.200’den fazla adresten, o anki değerle yaklaşık 116 milyon USD’ye denk gelen o ana kadarki toplamın yaklaşık 1.816 BTC’ye ulaştığını bildirdi. Diğer araştırmacılar farklı doğrulama kuralları kullandı ve sonradan kısmen farklı toplamlar açıkladı. Dolayısıyla bu rakamlar kesinleşmiş nihai kayıtlar olarak değil, olayın ölçeğine ilişkin kanıt olarak okunmalıdır.

Coinkite’ın [güncel güvenlik durumu sayfası](https://coldcard.com/security/status), resmî olay sonrası incelemenin halen sürdüğünü açıkça belirtiyor ve bildirilen her kaybın tek tek ilişkilendirildiğini ileri sürmüyor. Bu belirsizlik vakayı küçümsemek için gerekçe değildir. Doğrulanmış mekanizma, gözlemlenen işlemler, analitik ilişkilendirme ve nihai adli inceleme sonucu arasındaki ayrımı korumak için gerekçedir.

## Ürün yazılımını güncellemek eski bir tohumu onarmaz

Etkilenen kullanıcıların gözden kaçıramayacağı operasyonel gerçek budur. Düzeltilmiş ürün yazılımı gelecekteki tohum üretimini düzeltir; zaten var olan bir tohuma geriye dönük olarak entropi ekleyemez. O tohumdan yeni donanıma geri yüklenen bir cüzdan, aynı savunmasız sırrın denetiminde kalır. Metal muhafazayı değiştirmek, bir mobil uygulama kurmak veya sözcükleri başka bir markaya taşımak anahtarı değiştirmez. Fonlar, yeni oluşturulmuş ve bağımsız biçimde korunan bir tohumdan türetilen adreslere taşınmalıdır.

3 Eylül 2026’da doğrulandığı üzere Coldcard’ın durum sayfası, Mk4/Mk5 standart 5.6.1 ve Q standart 1.5.1Q sürümlerini önerilen standart sürümler olarak listeliyordu. Düzeltilmiş en düşük sürümler Mk2/Mk3 için 4.2.0 veya sonrası; Mk4/Mk5 standart için 5.6.0 veya sonrası; Q standart için 1.5.0Q veya sonrası; Mk4/Mk5 Edge için 6.6.0X veya sonrası ve Q Edge için 6.6.0QX veya sonrasıydı. Sürüm kanalları önemlidir: Sayısal olarak daha yüksek bir Edge sürümü, düzeltilmiş bir standart sürüme kendiliğinden eşdeğer değildir.

### Etkilenmiş olabileceğinizi düşünüyorsanız

- 

Muhafazaya güvenmeyi bırakın. Modeli, sürüm kanalını, tohum oluşturulurken kullanılan ürün yazılımını ve resmî bağımsız zar istisnasının açıkça geçerli olup olmadığını belirleyin. Emin değilseniz tohumu etkilenmiş kabul edin.

- 

Yalnızca resmî talimatları kullanın. Coldcard duyurusunu ve güvenlik durumu sayfasını doğrudan açın, imzalı ürün yazılımını ve yayımlanmış karma değerlerini doğrulayın, talep etmediğiniz “taşıma yardımı” tekliflerini reddedin. Meşru hiçbir yardımcı kurtarma ifadenize ihtiyaç duymaz.

- 

Hatanın giderildiği bir ortamda tümüyle yeni bir tohum oluşturun. Eski ifadedeki sözcükleri düzenlemeyin, karıştırmayın veya ifadeye sözcük eklemeyin. Yeni bir cüzdan yeni entropi gerektirir. Önemli bir bakiye söz konusuysa tek güven kökü bir sağlayıcının tohum üretim yolu olmasın diye bağımsız bir uygulamayı veya doğru tasarlanmış çoklu imza politikasını değerlendirin.

- 

Cüzdana fon aktarmadan önce kurtarmayı doğrulayın. Yedeği gizli biçimde kaydedin, denetimli bir süreçte geri yükleyin ve beklenen herkese açık parmak izini veya alım adresini doğrulayın. Hiç sınanmamış bir yedek yalnızca bir varsayımdır.

- 

Önce küçük bir deneme tutarı, ardından kalanı taşıyın. Bakiyenin tamamını taşımadan önce hedef adresi ve işlem onayını doğrulayın. Telaşlı doğaçlamalardan kaçının; ancak sakin bir prosedürü, açığa çıkmış bir tohumu erteleme izniyle karıştırmayın.

- 

Eski tohumu kullanımdan kaldırın. Ürün yazılımı güncellemesi ve sonradan eklenen güçlü bir parola ifadesi onu onarmaz. Sırrın gereksiz kopyalarını tutmadan vergi veya hukuk amacıyla gereken kayıtları saklayın.

Coinkite, etkilenen Add Dice Rolls iş akışında en az 50 adil, bağımsız ve gizli zar atışının yalnızca zarlardan en az 128 bit; 99 veya daha fazla atışın ise yaklaşık 256 bit katkı sağladığını belirtiyor. Kesin koşullar önemlidir. Dizi kaydedildiyse, gözlemlendiyse, yanlıysa, bağımsız değilse veya belirsizse sırf sayıdan güvenlik sonucu çıkarmayın. Önceden var olan güçlü bir BIP39 parola ifadesi ek bir engel oluşturabilir; ancak Coinkite yine de taşımayı öneriyor ve parola ifadesinin tohumu onardığını söylemiyor.

## Cihaz ele geçirilmedi—daha derin uyarı da budur

Her kaybı “donanım cüzdanı saldırısı” diye adlandırmak, farklı birçok arıza sınıfını tek bir dramatik ifadede birleştirir. Bu da hangi denetimlerin yardımcı olabileceğini belirsizleştirir. Coldcard vakasında saldırgan; her mağdurun elindeki kasayı, tuş takımını, USB denetimlerini veya güvenli elemanı aşmadı. Kök sır sıralanabilir olduğu için cihazı bütünüyle atladı.

Bir güvenlik sınırı yalnızca içinden geçeni korur. Güvenli elemana giren anahtar zayıfsa, kötü amaçlı ürün yazılımı anahtarı imzalar üzerinden sızdırıyorsa, ekran saldırganın denetimindeki bir hedefi gösteriyorsa veya bir kişi aktarımı yetkilendirmeye zorlanıyorsa özel donanımın varlığı saldırıya yanıt oluşturmaz.

## Donanım cüzdanı kaynaklı kayıpların tümü birbirine benzemez

Belgelenmiş çeşitli vakalar ve araştırma kapsamında gerçekleştirilen gösterimler, bu kategorinin neden kesinlik gerektirdiğini ortaya koyuyor. Bunlar donanım cüzdanlarının yararsız olduğunu kanıtlamaz. Donanımın riski yongalar, ürün yazılımları, tedarik zincirleri, ana makine yazılımları, imzalama protokolleri, yedekler ve insan prosedürlerinden oluşan farklı bir sisteme taşıdığını gösterir.

### 1. Hata enjeksiyonu ve tohumun fiziksel olarak çıkarılması

2020 yılında [Kraken Security Labs](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets), Trezor One ve Model T cihazlarına karşı gerilim hatası oluşturma tekniğini açıkladı. Kraken, yaklaşık 15 dakikalık fiziksel erişimin şifrelenmiş tohum materyalinin çıkarılmasına olanak verebileceğini ve ardından kısa bir PIN’in kaba kuvvetle çözülebileceğini bildirdi. Önerdiği uygulanabilir önlem, cihazda saklanmayan güçlü bir BIP39 parola ifadesiydi. Kraken, KeepKey’e karşı benzer bir saldırı sınıfını da belgeledi.

Bu, Coldcard’dakinden farklı bir tehdittir. Hedef cihazın fiziksel olarak elde bulundurulmasını ve laboratuvar tarzı hata enjeksiyonunu gerektirir. Kurcalamaya karşı direncin seçilen mikrodenetleyiciye ve depolama tasarımına bağlı olduğunu, PIN’in ise mutlaka yüksek entropili bir şifreleme sırrı olmadığını gösterir.

### 2. Gerçek bir donanım imzalayıcının çevresindeki yazılımın ele geçirilmesi

Aralık 2023’te yaşanan [Ledger Connect Kit tedarik zinciri olayı](https://www.ledger.com/blog/security-incident-report), güvenliği ihlal edilmiş bir paketi yükleyen dApp’lere kötü amaçlı kod enjekte etti. Ledger’a göre kod, EVM kullanıcılarını cüzdanları boşaltan işlemleri imzalamaları için aldattı. Donanım cihazları tohumlarını kendiliğinden ifşa etmedi; çevrelerindeki sistem, meşru imzalayıcılara kötü niyetli bir işlem sundu.

Bu arıza sınıfı, “anahtar cihazdan hiç çıkmadı” ifadesinin neden gerekli ama yetersiz olduğunu açıklar. Kullanıcı, ana makine veya ekran imzalanan şeyi güvenilir biçimde anlayamadığında güvenli bir anahtar yanlış işlemi de kurallara uygun biçimde yetkilendirebilir. Anlaşılır işlem çözümlemesi, güvenilir ekranlar, dar kapsamlı izinler, bağımlılık denetimleri ve kör imzalamaya karşı direnç saklama güvenliğinin parçalarıdır.

### 3. Sırları olağan imzalar üzerinden sızdıran kötü amaçlı ürün yazılımı

Block araştırmacıları, [uygulamalı bir araştırma saldırısı yayımladı](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet); bu saldırıda güvenliği ihlal edilmiş cüzdan ürün yazılımı, gizli materyali görünüşte olağan imzalara örtülü biçimde kodluyor. Bu tehdit modeli; tedarik zinciri ihlali, içeriden birinin eylemi, derleme sisteminin ele geçirilmesi veya imzalama anahtarının ele geçirilmesi gibi yollarla ürün yazılımının ihlal edildiğini varsayıyor. İmzalı işlemin kendisi veri sızdırma kanalına dönüşüyorsa ağdan fiziksel yalıtım işe yaramaz.

Yeniden üretilebilir derlemeler, birden çok bağımsız tarafın derleme yapması, sabitlenmiş bağımlılıklar, güvenli önyükleme ve çoklu imza çeşitliliği işte burada anlam kazanır. Bunlar bir zincirdeki belirli halkaları ele alır. Tasarımı, kaynağı veya operatörü sihirli biçimde onaylamaz.

### 4. Yedeğin açığa çıkması, adres değiştirme ve zorlama

Gerçek hırsızlıkların çoğu silikondaki bir açığı hiç kullanmaz. Saldırganlar tohum yedeklerini çalar veya fotoğraflar, alım adresini değiştirir, destek görevlisi kimliğine bürünür, satın alma ya da sevkiyat sürecini ihlal eder, zayıf PIN’li bir cihazı ele geçirir veya sahibini iş birliğine zorlar. Kurtarma ifadesi tasarımı gereği taşınabilir bir ana kimlik bilgisidir: onu elde eden herkes, asıl cihaz nerede olursa olsun cüzdanı başka bir yerde geri yükleyebilir.

## Daha fazla karmaşıklık güvenliği neden kötüleştirebilir?

Karmaşıklık bazen gerekçelidir. Ayrı bir ekran, işlem incelemesini daha güvenilir kılabilir. Güvenli eleman, fiziksel çıkarma maliyetini yükseltebilir. Çoklu imza, tek bir anahtarın tek hata noktası olmasını önleyebilir. Ancak eklenen her mekanizma aynı zamanda arayüzler, durumlar, güncelleme yolları, bağımlılıklar, kurtarma prosedürleri ve varsayımlar yaratır. Doğru soru “Bu karmaşık mı?” değil, “Her bileşen hangi tehdidi denetliyor ve hangi yeni arıza biçimlerini ortaya çıkarıyor?” sorusudur.

Saltzer ve Schroeder’ın klasik [mekanizma ekonomisi](https://www.ojp.gov/ncjrs/virtual-library/abstracts/protection-information-computer-systems) ilkesi, inceleme ve anlamanın mümkün kalabilmesi için koruma tasarımlarının olabildiğince basit ve küçük olması gerektiğini söyler. Modern [NIST sistem güvenliği kılavuzu](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-160v2r1.pdf) da saldırı yüzeyinin azaltılmasını ve analizi güç, büyük, çok işlevli bileşenleri mimari kaygılar olarak ele alır. Sadelik, denetimlerin yokluğu değildir. Davranışı açıklanamayan, sınanamayan ve doğru biçimde işletilemeyen denetimleri eklemeyi reddetmektir.

- 

Daha fazla kod, daha fazla olası kusur yaratır. Ayrıca eksiksiz incelemeyi daha maliyetli, etkileşimleri muhakeme etmeyi daha güç kılar.

- 

Daha fazla mod yapılandırma riski yaratır. Standart ve Edge ürün yazılımları, birden fazla tohum iş akışı, parola ifadeli cüzdanlar, USB ve ağdan fiziksel olarak yalıtılmış yollar ile yedek çeşitleri tek başlarına güvenli olabilirken bir araya geldiklerinde kafa karıştırıcı hâle gelebilir.

- 

Daha fazla arayüz, anlam aktarımı riski yaratır. Donanım ekranı, ana makine uygulaması, QR biçimi, microSD iş akışı, tarayıcı bağlayıcısı ve ağın arka uç sistemi, kullanıcının tam olarak neyi yetkilendirdiği konusunda mutabık olmalıdır.

- 

Daha fazla prosedürel yük uyumu azaltabilir. Güvenli yol zorsa insanlar doğrulamayı atlar, güncellemeleri erteler, yedekleri yeniden kullanır veya acil durum talimatlarını anlamadan izler.

- 

Daha fazla güven duygusu kaybı büyütebilir. “Soğuk”, “ağdan yalıtılmış” veya “hacklenemez” diye pazarlanan bir ürün, kullanıcıyı daha fazla değeri tek bir tohumun ardında birleştirmeye yöneltebilir. Yoğunlaşma, gizli tek bir kusuru yıkıcı bir sonuca dönüştürür.

Katmanlar bağımsız olduğunda derinlemesine savunma değerlidir. Aynı gerçekleştirimin, aynı entropi kaynağının, aynı sağlayıcının veya aynı kurtarma sırrının tekrarı bağımsız savunma değildir.

## Açık kaynak, denetimler, yeniden üretilebilir derlemeler ve yapay zekâ incelemesi eş anlamlı değildir

Coldcard’ın geçmişi son derece öğreticidir: Ürün yazılımı herkese açıktı ve yeniden üretilebilir derleme belgeleri mevcuttu; buna karşın savunmasız yol yıllarca sürümlerde kaldı. Bu, açıklığı yararsız kılmaz. Kanıtların erişilebilirliği ile doğru özelliğin gerçekten incelenmesinin farklı şeyler olduğunu gösterir.

- 

Açık kaynak dışarıdakilerin uygulamayı inceleyebileceği anlamına gelir. Güvenlik açısından kritik her yolun biri tarafından incelendiğini ya da kurulu ikili dosyanın herkese açık kaynak ağacından üretildiğini ortaya koymaz.

- 

Bağımsız denetim kapsamı sınırlı bir çalışmadır. Değeri; adı belirtilen inceleyene, tam commit’e veya sürüme, tehdit modeline, sınanan özelliklere, kapsam dışı bırakılanlara, bulgulara ve düzeltme kanıtına bağlıdır. Kapsam belirtilmeden kullanılan “denetlendi” ifadesi bir slogandır.

- 

Yeniden üretilebilir derleme bağımsız tarafların yayımlanmış bir tarifi izleyip derleme çıktılarını karşılaştırmasını sağlar. Eşleşme, kaynağı bir sürüm çıktısıyla ilişkilendirebilir; kaynağın doğru olduğunu kanıtlamaz.

- 

App Store incelemesi ve kod imzalama dağıtım ve platform denetimleri sağlar. Bunlar tek başına bir App Store ikili dosyasının herkese açık bir depoyla bit düzeyinde aynı olduğunu kanıtlamaz.

- 

Yapay zekâ destekli inceleme geniş kod tabanlarında arama yapabilir, karşıt hipotezler üretebilir, değişmezleri karşılaştırabilir ve insan analizini hızlandırabilir. Bir model bağlamı gözden kaçırabilir, yanlış bir öncülü kabul edebilir veya makul görünen ama hatalı bir bulgu üretebilir. Yapay zekâ incelemesi başka bir bakış açısıdır; sertifikasyon makamı değildir.

Coldcard’ın güncel durum sayfası, iyi kapsam diline örnek oluşturuyor: Hedefe yönelik gerçek cihaz RNG enstrümantasyonunu, kaynak incelemelerini, bir acil düzeltme incelemesini ve yeniden üretilebilir derlemeyle birlikte zar yolunun izlenmesini adlandırıyor; ardından bu kontrollerin her ürün yazılımı ikilisinin eksiksiz denetimi olmadığını ve kusurların bulunmadığını garanti etmediğini açıkça belirtiyor. Bu cümle, kapsamı belirtilmemiş bir rozetten daha değerlidir.

## Oath dürüstçe ne iddia edebilir?

Oath, özel bir donanım imzalayıcı yerine kaynak kodu erişilebilir bir iPhone ve iPad uygulamasına dayanan farklı bir saklama mimarisi üzerine kuruludur. [Herkese açık depo](https://github.com/devdasx/oath-wallet), mobil istemciyi ve derleme talimatlarını MIT lisansı altında sunar. [Yayımlanmış güvenlik modeli](https://oathwallet.org/data/security-model.json), cüzdan sırlarının yalnızca bu cihaza özgü korumayla uygulama kapsamındaki iOS Anahtar Zinciri üzerinden saklandığını; yerel veritabanının ise kurtarma ifadeleri veya özel anahtarlar yerine opak referanslar tuttuğunu belirtir. İşlemler, imzalanmış veriler ağ altyapısına gönderilmeden önce cihaz üzerinde oluşturulur ve imzalanır.

Apple’ın [platform güvenliği belgeleri](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web), zorunlu kod imzalamayı, kimliği belirlenmiş geliştiricileri, otomatik ve insan eliyle App Store incelemesini, sanal alan kullanımını ve çalışma zamanında imza denetimini açıklar. [Anahtar Zinciri belgeleri](https://support.apple.com/guide/security/secb0694df1a/1/web/1) ise öğe bazında korumayı ve Anahtar Zinciri anahtarlarının işlenmesinde Secure Enclave’in rolünü açıklar. Bunlar gerçek platform denetimleridir. Oath’ın blok zinciri özel anahtarlarının kendilerinin Secure Enclave anahtarları olduğu iddiası değildir; Oath da böyle bir iddiada bulunmaz.

Oath ayrıca ürün yüzeyini bilinçli olarak daraltır. Saklama hizmeti sunan bir hesap işletmez veya şirketçe tutulan bir kurtarma kopyası bulundurmaz; temel tasarımı da cüzdanı bir alım-satım masasına, takas motoruna veya genel amaçlı cüzdan içi tarayıcıya dönüştürmekten kaçınır. Sürüm 2.40.12, kullanıcılar zar, yazı tura veya rakamlarla entropi oluştururken aşırı tekrar, baskınlık ve öngörülebilir döngülere yönelik fiziksel rastgelelik sağlık kontrolleri ekledi. Bu kontroller bariz arıza örüntülerini saptayabilir; fiziksel bir sürecin adil veya gizli olduğunu kanıtlayamaz.

### Oath bir donanım cüzdanından daha güvenli olabilir mi?

Bazı tehdit modelleri için evet. Evrensel bir iddia olarak hayır. Bir telefon cüzdanı, özel bir cihazın üretim ve sevkiyat yolundan kaçınabilir; değerli varlıkların kişinin gözetiminde olduğunu gözle görünür biçimde işaret eden nesnelerin sayısını azaltabilir; hızlı imzalı güncellemelere ve olgun sanal alan korumasına sahip bir platform kullanabilir; ayrıca incelenebilir bir uygulamayı, kullanıcıların doğru biçimde kullanma olasılığının daha yüksek olduğu tanıdık bir arayüze yerleştirebilir. Daha küçük bir özellik yüzeyi; tarayıcı, takas, onay ve cihazlar arası anlam aktarımından doğan risk sınıflarını bütünüyle ortadan kaldırabilir.

Başka tehdit modellerinde, iyi tasarlanmış ayrı bir imzalayıcı önemli bir sınırdır. Telefon işletim sistemi veya cüzdan uygulaması süreci ele geçirilirse fiziksel ayrım ve bağımsız olarak güvenilir bir ekran, ağa bağlı ana makinenin anahtarı elde etmesini veya kötüye kullanmasını önleyebilir. Kurumlar veya yaşamı değiştirecek büyüklükteki değerler için daha güçlü mimari; bağımsız uygulamalar, bağımsız entropi, ayrı konumlar ve belgelenmiş kurtarma kullanan, dikkatle sınanmış bir çoklu imza politikası olabilir—tek bir telefon ile tek bir donanım kutusunun yarışması değil.

Bu nedenle “donanım” sözcüğü analizi hiçbir zaman sonlandırmamalıdır. iPhone da donanımdır. Önemli farklar; hangi kodun yürütüldüğü, nasıl derlenip dağıtıldığı, sırların nerede erişilebilir olduğu, kullanıcının neyi doğrulayabildiği, işlemlerin nasıl gösterildiği, güncellemelerin nasıl gerçekleştiği ve hangi tekil arızaların fonları hareket ettirebildiğidir.

### Kanıtın sınırı Oath için de önemlidir

Oath’ın web sitesi şu anda uygulamanın bağımsız olarak denetlendiğini ve yeniden üretilebilir biçimde derlendiğini belirtiyor. [Herkese açık denetim kaydı](https://oathwallet.org/security), inceleyenlerin adları, kesin kapsam, tarihler, incelenen sürümler, raporlar, bulgular, düzeltmeler, özet değerleri ve yeniden üretilebilirlik materyalleri için esas başvuru noktası olarak belirlenmiştir. Bu makalenin yayımlandığı tarihte söz konusu kayıt henüz bu somut kanıt materyallerini göstermiyordu. Herkese açık GitHub deposunda da bir App Store ikili dosyası eşleşmesinin bağımsız biçimde yeniden üretilebileceği sürüm çıktıları bulunmuyordu.

Bu nedenle bu makale; “App Store ikili dosyasındaki her satırın güvenli olduğunun kanıtlandığını”, birkaç şirketin her davranışı onayladığını veya yapay zekânın tüm uygulamayı doğruladığını iddia etmez. Bu ifadeler kamuya açık kanıtların sınırını aşardı. Teknik açıdan doğru ayrım şudur: Kaynak kod GitHub’da yayımlanırken Apple, imzalı ve derlenmiş bir ikili dosyayı App Store üzerinden dağıtır. İkisi arasında bağ kurmak için herkese açık bir derleme tarifi, değiştirilemez kaynak revizyonu, bağımlılık kilidi, elde edilmiş App Store paketi, Apple imzalama etkilerini ele alan bir normalleştirme yordamı, eşleşme sonucu ve bağımsız tasdik gerekir.

Doğrulama, bir iddia kuşkucu bir üçüncü kişinin onu yeniden üretmesine yetecek kadar kanıt içerdiğinde en güçlü hâline ulaşır. Oath da her donanım cüzdanı sağlayıcısı kadar katı biçimde bu standarda göre değerlendirilmelidir.

## Üniversite düzeyinde bir doğrulama paketi neleri içermelidir?

Araştırmacılar, denetçiler, gazeteciler ve kurumsal değerlendiriciler açısından güvenilir bir cüzdan güvenliği iddiası, rozetlerden oluşan bir duvar değil, içinde gezinilebilir bir kanıt zinciri olmalıdır. En azından şunları isteyin:

- 

Kesin bir tehdit modeli. Uzaktan ele geçirme, fiziksel çıkarma, kötü amaçlı güncellemeler, derleme sisteminin ele geçirilmesi, zayıf entropi, işlem hedefinin değiştirilmesi, yedek hırsızlığı, zorlama ve kullanılabilirliği ayrı ayrı adlandırın.

- 

Değiştirilemez, incelenmiş bir revizyon. Kapsama alınan commit’i, bağımlılık grafiğini, derleyici ve SDK sürümlerini, derleme bayraklarını, yetkileri ve yapılandırmayı belirleyin.

- 

Adı belirtilmiş bağımsız bir rapor. İnceleyeni, metodolojiyi, tarihleri, kapsam dışı bırakılanları, önem derecesi ölçütlerini, bulguları ve her düzeltmenin tamamlandığını göstermek için kullanılan kanıtı yayımlayın.

- 

Kaynaktan ikili dosyaya yeniden üretilebilirlik. Tam olarak ilgili herkese açık sürüme bağlı eksiksiz bir tarif ve bağımsız derleme sonuçları sağlayın. Belirlenimci olmayan veya imzalamadan kaynaklanan farklılıkları açıklayın.

- 

Entropi yoluna ilişkin kanıt. Kaynağı gerçek donanım üzerinde sınayın, arıza davranışını doğrulayın, sessiz geri dönüşü reddedin ve sürüm derlemesinin kullandığı kesin yolu izleyin. Yalnızca istatistiksel çıktı testleri, üretecin doğru bağlandığını kanıtlayamaz.

- 

Saldırgan senaryolu işlem testleri. Alıcı değiştirme, ücret manipülasyonu, kötü amaçlı üst veriler, kör imzalama sınırları, kesintiye uğrayan yayınlar ve tüm ekranlar ile imzalayıcılar arasındaki ayrıştırma uyuşmazlıklarını sınayın.

- 

Kurtarma ve güncelleme tatbikatları. Kısmi bilgiler, eski sürümler, taşıma, kayıp cihazlar ve bir güncellemenin mevcut sırları onaramama olasılığı dâhil olmak üzere talimatları gerçekçi zaman baskısı altında sınayın.

- 

Sürekli ve çeşitli inceleme. Belirlenimci testleri, statik analizi, insan uzmanları, fuzz testlerini, gerçek cihaz testlerini ve yapay zekâ destekli incelemeyi birbirini tamamlayan yöntemler olarak kullanın. Her yöntemin neyi ortaya koyduğunu ve neyi koymadığını kaydedin.

## Tehdit ekranın dışına taşabilir

Öz saklama, saklama hizmeti sağlayıcısını aradan çıkarabilir; ancak kişiyi nihai yetkilendirme sınırı hâline de getirebilir. Kriptografiyi kıramayan bir hırsız bunun yerine cüzdan sahibini, ailesini, evini, iş yerini veya kamusal kimliğini hedef alabilir. Özel donanım, kişinin saklamayı ciddiye aldığını görünür biçimde duyurarak ya da saldırganın bulmayı beklediği fiziksel bir nesne yaratarak bu hedeflemeyi bazen kolaylaştırabilir. Bakiyeler görünüyorsa telefon da varlıkları açığa çıkarabilir. İki donanım biçimi de zorlama sorununu çözmez.

Hakemli bir 2024 araştırması olan [“İngiliz Anahtarı Saldırılarını İncelemek: Kripto Para Kullanıcılarını Hedef Alan Fiziksel Saldırılar”](https://doi.org/10.4230/LIPIcs.AFT.2024.10), görüşmeleri, forumları ve 146 haber makalesini analiz etti. Filtrelenmiş haber veri kümesi, bildirilen baskın eylem türü olarak 24 kaçırma ve 6 cinayet dâhil 105 fiziksel saldırı vakası içeriyordu. Yazarlar eksik bildirim sorununu vurguluyor ve deneyimli güvenlik uygulayıcılarının da bağışık olmadığını saptıyor. Bu rakamlar araştırmanın veri kümesini betimler; dünya çapındaki görülme oranını göstermez ve belirli bir cüzdan türünün her suça neden olduğunun kanıtı değildir.

Tehlike kuramsal değildir. 2024 yılında [Amerika Birleşik Devletleri Adalet Bakanlığı](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency), mağdurları kripto para hesaplarını boşaltmaya zorlamak için gözetim, konut baskınları, kaçırma, saldırı ve tehdit kullanan bir suç ortaklığına ilişkin mahkûmiyetleri açıkladı. Çıkarılacak ders paniğe kapılmak veya meşru yardımdan saklanmak değildir. Operasyonel gizliliği ve kişisel güvenliği cüzdan tasarımının bir parçası olarak ele almaktır.

### İnsan güvenliği, varlık kurtarmadan önce gelir

- 

Bakiyeleri veya saklama ayrıntılarını duyurmayın. Herkese açık adresler, ekran görüntüleri, konferans konuşmaları, sosyal medya paylaşımları, sevkiyat kayıtları ve atılmış ambalajlar kimlik, konum ve algılanan servet arasında bağ kurabilir.

- 

Gündelik fonları rezervlerden ayırın. Harcama cüzdanı, uzun vadeli varlıkların tamamını açığa çıkarmamalı veya denetlememelidir. Her varlığı ve kurtarma yolunu hemen erişilebilir tek bir sırrın ardında birleştirmekten kaçının.

- 

Önemli tutarlar için bağımsız yetkilendirme kullanın. İyi tasarlanmış çoklu imza, çalınmış tek bir cihazın veya zorlamanın uygulandığı tek bir konumun yeterli olmasını önleyebilir; ancak bunun için anahtarların, uygulamaların ve kurtarma materyallerinin gerçekten ayrılmış olması gerekir.

- 

Arayüzün gösterdiklerini koruyun. Uygulama kilidi ve uygulama değiştirici gizlilik denetimlerini kullanın, bakiyenin tamamını kamusal alanda göstermekten kaçının ve ilgisiz varlıkları açığa çıkarmadan alıcıları doğrulayın.

- 

Yetkin yerel uzmanlarla plan yapın. Yüksek risk altındaki kişiler ve kurumlar; yargı alanlarını ve kişisel koşullarını anlayan uzmanlarla hukuka uygun fiziksel güvenlik, seyahat, olay müdahalesi, miras ve aile güvenliği prosedürleri geliştirmelidir.

- 

Bir cüzdan uğruna asla yaşamınızı riske atmayın. Hiçbir kurtarma ifadesi, cihaz, işlem veya tutar fiziksel yaralanmaya değmez. Yakın bir tehdit varsa insan güvenliğine öncelik verin ve bunu yapmak güvenli olduğunda yerel acil durum hizmetleriyle iletişime geçin.

## Çıkarılacak ders kabileci sadakat değil, kanıttır

Coldcard’ın arızası, güncel Coldcard cihazlarının tümünün güvensiz olduğunu, her donanım cüzdanının göstermelik olduğunu veya her telefon cüzdanının üstün olduğunu kanıtlamaz. Coinkite; düzeltilmiş sürümler, taşıma rehberi, hedefe yönelik bağımsız doğrulama ve bu kontrollerin neyi ortaya koyduğuna ilişkin açık sınırlar yayımladı. Sorumlu bir analiz hem vakanın ciddiyetini hem de düzeltme sicilini kabul etmelidir.

Aynı şekilde Oath da yalnızca başka bir mimariyi eleştirerek güveni miras almamalıdır. Herkese açık kaynağı, dar saklama modeli, Apple platform denetimleri, yerel imzalama ve incelenebilirlik anlamlıdır. Adı belirtilen bir üçüncü taraf kapsamı ve bulguları yayımladığında, araştırmacılar dağıtılan ikili dosyayı değiştirilemez kaynaktan yeniden üretebildiğinde ve yapay zekâ destekli inceleme belirlenimci testler ile hesap verebilir insan yargısıyla eşleştirildiğinde bunlar güçlenir.

Kalıcı sonuç daha basittir: güvenlik kutunun malzemesi değildir; sırrın niteliği, sistemin bütününün davranışı, savunmalarının bağımsızlığı, arayüzünün açıklığı ve her önemli iddiayı doğrulamak için erişilebilen kanıtlardır. Karmaşıklık gerekli olabilir; ancak denetim altına aldığı her bir tehditle yerini ayrı ayrı hak etmelidir.

Oath’ın şu konulardaki kılavuzlarıyla devam edin: [fiziksel rastgelelikten entropi oluşturma](https://oathwallet.org/articles/build-wallet-with-dice-coin-flips-random-digits), [BIP39 parola ifadeleri](https://oathwallet.org/articles/add-bip39-passphrase-oath-wallet), [öz saklama güvenlik modeli](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model) ve [uygulama parolası ile gizlilik denetimleri](https://oathwallet.org/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy).

## Birincil ve teknik kaynaklar

- 

[Coinkite: Coldcard güvenlik duyurusu](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) — etkilenen sürümler, entropi kapsamı, düzeltilmiş sürümler ve taşıma rehberi.

- 

[Coldcard: güncel güvenlik durumu](https://coldcard.com/security/status) — güncel sürümler, bağımsız doğrulamanın kapsamı, sınırlamalar ve olay sonrası incelemenin durumu.

- 

[TRM Labs: 5 Ağustos tarihli zincir üstü değerlendirme](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) — belirli tarihe ait kayıp tahmini ve işlem akışı analizi.

- 

[Kraken Security Labs: Trezor hata enjeksiyonu açıklaması](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) — fiziksel erişimle tohum çıkarma ve parola ifadesiyle risk azaltma.

- 

[Ledger: Connect Kit olay raporu](https://www.ledger.com/blog/security-incident-report) — kötü amaçlı bağımlılığın yayımlanması ve kullanıcı imzalamalarına etkisi.

- 

[Block: ürün yazılımı arka kapısı araştırması](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) — sırların imzalar üzerinden sızdırılması ve tedarik zinciri önlemleri.

- 

[Apple Platform Güvenliği: uygulama güvenliği ve kod imzalama](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) — iOS dağıtımı, sanal alan kullanımı ve çalışma zamanı bütünlüğü denetimleri.

- 

[Ordekian, Atondo-Siu, Hutchings ve Vasek: İngiliz anahtarı saldırıları araştırması](https://doi.org/10.4230/LIPIcs.AFT.2024.10) — hakemli fiziksel güvenlik analizi.

- 

[ABD Adalet Bakanlığı: kripto para bağlantılı konut baskını mahkûmiyetleri](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) — belgelenmiş fiziksel zorlama ve gözetim.

Oath’ın Coldcard, Coinkite, Trezor, Kraken, Ledger, Block veya atıf yapılan araştırmacılarla herhangi bir bağlantısı yoktur; bunların hiçbiri Oath’ı desteklememektedir. Ürün ve şirket adları ilgili sahiplerine aittir. Bu makale güvenlik eğitimi amacı taşır; kişiye özel finans, hukuk veya acil durum tavsiyesi değildir. Kurtarma ifadesini, özel anahtarı, cüzdan parola ifadesini, uygulama parolasını veya yedek parolasını hiçbir zaman bir web sitesine, destek görevlisine, araştırmacıya ya da yapay zekâ asistanına vermeyin.
