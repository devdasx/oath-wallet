# Krisis Seed Lemah Coldcard: Kompleksitas Tidak Sama dengan Keamanan

Oath Research · September 3, 2026

https://oathwallet.org/id/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security

Insiden Coldcard 2026 tidak membobol perangkat dari jarak jauh. Insiden itu mengungkap persoalan yang lebih mendasar: selubung canggih tidak dapat melindungi seed yang sudah dapat diprediksi sejak dibuat.

Catatan riset, 3 September 2026. Artikel ini membedakan fakta yang telah dikonfirmasi, pernyataan vendor, estimasi on-chain, dan analisis kami sendiri. Laporan teknis pascainsiden resmi Coinkite masih belum diterbitkan ketika artikel ini disusun. Total kerugian berubah seiring para penyelidik mengaitkan transaksi tambahan, sehingga angka-angka di bawah ini merupakan cuplikan bertanggal, bukan perhitungan akhir.

Pada Juli 2026, Bitcoin lenyap dari ribuan alamat yang pemiliknya meyakini bahwa kunci mereka dilindungi oleh dompet perangkat keras Coldcard. Koreksi pertama dan terpenting juga merupakan hal yang paling mengungkap persoalan: perangkat tersebut tidak diambil alih dari jarak jauh. Kesalahan firmware telah melemahkan keacakan yang digunakan ketika beberapa dompet dibuat. Penyerang dapat menelusuri ruang kunci yang diperkecil di tempat lain, memulihkan kandidat kunci privat, membandingkan alamat turunannya dengan blockchain Bitcoin publik, dan membelanjakan dana pada alamat yang cocok tanpa menyentuh perangkat kerasnya.

Sebuah brankas dapat sangat tangguh secara fisik, tetapi tetap gagal jika rahasia yang ditempatkan di dalamnya sudah dapat diprediksi sejak awal.

Itulah sebabnya insiden ini penting jauh melampaui satu vendor. Insiden ini menggugat jalan pintas pemikiran yang menenteramkan: perangkat keras berarti aman, lebih banyak komponen berarti lebih banyak perlindungan, dan daftar fitur yang panjang berarti jaminan tinggi. Tak satu pun pernyataan itu merupakan model ancaman. Keamanan berasal dari sistem secara keseluruhan—entropi, firmware, perangkat keras, proses build, distribusi, antarmuka, cadangan, perilaku operator, dan keselamatan fisik—serta dari bukti yang memungkinkan pihak luar menguji klaimnya.

## Apa yang terjadi pada Coldcard

Menurut [imbauan resmi Coinkite](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/), firmware yang terdampak menggunakan jalur pembuatan seed yang cacat. Seed dompet yang dibuat pada firmware Mk2 atau Mk3 versi 4.0.1 hingga 4.1.9 berisiko, kecuali telah ditambahkan entropi dadu privat dan independen yang memadai atau passphrase BIP39 yang kuat dan unik menciptakan penghalang tambahan. Imbauan tersebut juga mencakup seed yang dihasilkan pada perangkat Mk4, Mk5, dan Q sebelum rilis Standard atau Edge yang telah diperbaiki. Untuk perangkat yang lebih baru itu, Coinkite melaporkan sekitar 72 bit entropi, bukan 128 bit sebagaimana dimaksud.

Kegagalan itu berasal dari firmware yang dirilis pada Maret 2021 dan tetap laten selama bertahun-tahun. Perlindungan perangkat keras bekerja pada rahasia yang diberikan kepadanya; masalahnya, proses pembuatan rahasia tidak menyediakan tingkat ketidakpastian yang diharapkan. Setelah penyerang dapat mengenumerasi seed yang masuk akal dengan biaya yang layak, blockchain publik menyediakan uji keanggotaan yang sempurna: turunkan alamat, cari yang menyimpan nilai, lalu tanda tangani dengan kunci mana pun yang berhasil dipulihkan. Tidak diperlukan prompt phishing, sesi USB, paket curian, maupun akses fisik.

### Mengapa entropi lemah berakibat fatal

Seed dompet tidak aman hanya karena tampak acak bagi manusia. Seed aman ketika tidak ada penyerang yang secara layak dapat membedakan atau mengenumerasi kemungkinan yang mendasarinya. Setiap bit entropi melipatgandakan ruang pencarian. Penurunan dari 128 bit menjadi 72 bit bukan membuat seed “sedikit lebih lemah”; penurunan itu menghilangkan 56 pelipatan beban kerja. Ruang pencarian efektif yang lebih kecil lagi mengubah pencarian yang mustahil secara astronomis menjadi sebuah proyek rekayasa.

Kata-kata pemulihan tetap valid secara sintaksis. Alamatnya tampak biasa. Perangkat keras menandatangani secara normal. Cadangan dapat dipulihkan dengan benar. Ini adalah kegagalan senyap: setiap ritual yang terlihat dapat berhasil ketika landasan keamanannya sebenarnya telah runtuh. Itulah tepatnya alasan pembuatan angka acak membutuhkan pengujian deterministik pada rangkaian penghubung, instrumentasi perangkat nyata pada sumber entropi, dan bukti rilis yang menghubungkan sumber yang telah ditinjau dengan firmware yang dikirimkan.

### Pencurian berlangsung dalam beberapa gelombang

Pada 30 Juli, transaksi penyapuan pertama yang dilaporkan memindahkan sekitar 594 BTC dari sekitar 500 alamat dalam waktu kurang lebih 25 menit. Atribusi berikutnya memperluas cakupan insiden. Sebuah [asesmen TRM Labs yang diterbitkan pada 5 Agustus](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) mencatat total sementara mendekati 1.816 BTC—sekitar USD 116 juta pada cuplikan waktu tersebut—dari lebih dari 5.200 alamat dalam empat gelombang. Penyelidik lain menggunakan aturan konfirmasi yang berbeda dan kemudian melaporkan total yang agak berbeda. Karena itu, angka-angka tersebut harus dibaca sebagai bukti skala, bukan catatan akhir yang sudah disepakati.

Halaman [status keamanan terkini Coinkite](https://coldcard.com/security/status) secara eksplisit menyatakan bahwa laporan pascainsiden resmi masih dalam proses dan tidak mengklaim bahwa setiap kerugian yang dilaporkan telah diatribusikan satu per satu. Ketidakpastian itu bukan alasan untuk mengecilkan insiden ini. Justru, itu merupakan alasan untuk mempertahankan perbedaan antara mekanisme yang terverifikasi, transaksi yang teramati, atribusi analitis, dan kesimpulan forensik akhir.

## Memperbarui firmware tidak memperbaiki seed lama

Inilah fakta operasional yang tidak boleh terlewat oleh pengguna terdampak. Firmware yang telah diperbaiki mengoreksi pembuatan seed pada masa mendatang; firmware tersebut tidak dapat menambahkan entropi secara retroaktif ke seed yang sudah ada. Dompet yang dipulihkan dari seed itu ke perangkat keras baru tetap dikendalikan oleh rahasia rentan yang sama. Mengganti selubung logam, memasang aplikasi seluler, atau memindahkan kata-katanya ke merek lain tidak mengubah kunci. Dana harus dipindahkan ke alamat yang diturunkan dari seed yang baru dibuat dan dilindungi secara independen.

Berdasarkan verifikasi pada 3 September 2026, halaman status Coldcard mencantumkan Mk4/Mk5 Standard 5.6.1 dan Q Standard 1.5.1Q sebagai rilis Standard yang direkomendasikan. Versi minimum yang telah diperbaiki adalah Mk2/Mk3 4.2.0 atau lebih baru; Mk4/Mk5 Standard 5.6.0 atau lebih baru; Q Standard 1.5.0Q atau lebih baru; Mk4/Mk5 Edge 6.6.0X atau lebih baru; dan Q Edge 6.6.0QX atau lebih baru. Kanal rilis itu penting: versi Edge yang secara numerik lebih tinggi tidak otomatis setara dengan rilis Standard yang telah diperbaiki.

### Jika Anda mungkin terdampak

- 

Jangan lagi mengandalkan selubung fisik. Tentukan model, kanal rilis, firmware yang digunakan ketika seed dibuat, serta apakah pengecualian resmi untuk dadu independen jelas berlaku. Jika Anda ragu, anggap seed tersebut terdampak.

- 

Gunakan hanya petunjuk resmi. Buka imbauan Coldcard dan halaman status keamanannya secara langsung, verifikasi firmware yang ditandatangani dan hash yang dipublikasikan, serta tolak “bantuan migrasi” yang tidak diminta. Tidak ada pihak pemberi bantuan yang sah yang memerlukan frasa pemulihan Anda.

- 

Buat seed yang sepenuhnya baru di lingkungan yang telah diperbaiki. Jangan mengedit, mengacak ulang, atau menambahkan kata pada frasa lama. Dompet baru membutuhkan entropi baru. Untuk saldo yang signifikan, pertimbangkan implementasi independen atau kebijakan multisignature yang dirancang dengan tepat agar jalur seed dari satu vendor bukan satu-satunya akar kepercayaan.

- 

Verifikasi pemulihan sebelum mengirim dana. Catat cadangan secara privat, pulihkan dalam proses yang terkendali, dan konfirmasikan sidik jari publik atau alamat penerima yang diharapkan. Cadangan yang tidak pernah diuji hanyalah sebuah asumsi.

- 

Pindahkan sedikit dana sebagai pengujian, lalu sisanya. Verifikasi tujuan dan konfirmasi sebelum memindahkan seluruh saldo. Hindari improvisasi yang tergesa-gesa, tetapi jangan menyamakan prosedur yang tenang dengan izin untuk menunda penanganan seed yang telah terpapar.

- 

Pensiunkan seed lama. Pembaruan firmware dan passphrase kuat yang ditambahkan kemudian tidak memperbaikinya. Simpan catatan yang diperlukan untuk keperluan pajak atau hukum tanpa mempertahankan salinan rahasia yang tidak diperlukan.

Coinkite menyatakan bahwa setidaknya 50 lemparan dadu yang adil, independen, dan privat dalam alur kerja Add Dice Rolls yang terdampak menyumbangkan setidaknya 128 bit hanya dari dadu; 99 lemparan atau lebih menyumbangkan sekitar 256 bit. Kondisi tepatnya penting. Jika urutannya dicatat, diamati, bias, tidak independen, atau meragukan, jangan menciptakan rasa aman hanya dari jumlahnya. Passphrase BIP39 kuat yang telah ada sebelumnya mungkin menambah penghalang, tetapi Coinkite tetap menganjurkan migrasi dan tidak menyatakan bahwa passphrase memperbaiki seed.

## Perangkatnya tidak diretas—dan itulah peringatan yang lebih mendalam

Menyebut setiap kerugian sebagai “peretasan dompet perangkat keras” memampatkan beberapa kelas kegagalan yang berbeda menjadi satu frasa dramatis. Hal itu mengaburkan kontrol yang sebenarnya dapat membantu. Dalam insiden Coldcard, penyerang tidak menaklukkan casing, keypad, kontrol USB, atau secure element yang dimiliki tiap korban. Penyerang melewati perangkat karena rahasia akarnya dapat dienumerasi.

Batas keamanan hanya melindungi apa yang melintasinya. Jika kunci yang memasuki secure element lemah, jika firmware berbahaya membocorkannya melalui tanda tangan, jika layar menampilkan tujuan yang dikendalikan penyerang, atau jika seseorang dipaksa mengotorisasi transfer, keberadaan perangkat keras khusus tidak menanggulangi serangan tersebut.

## Kerugian akibat dompet perangkat keras tidak semuanya serupa

Sejumlah insiden terdokumentasi dan demonstrasi riset menunjukkan mengapa kategori ini membutuhkan ketepatan. Hal itu tidak membuktikan bahwa dompet perangkat keras tidak berguna. Justru, contoh-contoh tersebut menunjukkan bahwa perangkat keras memindahkan risiko ke sistem berbeda yang terdiri atas cip, firmware, rantai pasok, perangkat lunak host, protokol penandatanganan, cadangan, dan prosedur manusia.

### 1. Injeksi gangguan dan ekstraksi seed secara fisik

Pada 2020, [Kraken Security Labs mengungkapkan](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) teknik glitch tegangan terhadap perangkat Trezor One dan Model T. Kraken melaporkan bahwa akses fisik selama kurang lebih 15 menit dapat memungkinkan ekstraksi materi seed terenkripsi dan bahwa PIN singkat kemudian dapat dibobol dengan brute force. Mitigasi praktisnya adalah passphrase BIP39 kuat yang tidak disimpan pada perangkat. Kraken mendokumentasikan kelas serangan serupa terhadap KeepKey.

Ini merupakan ancaman yang berbeda dari Coldcard. Ancaman ini memerlukan penguasaan atas perangkat target dan injeksi gangguan bergaya laboratorium. Hal tersebut menunjukkan bahwa ketahanan terhadap manipulasi bergantung pada mikrokontroler dan desain penyimpanan yang dipilih, serta bahwa PIN belum tentu merupakan rahasia enkripsi berentropi tinggi.

### 2. Perangkat lunak yang disusupi di sekitar penanda tangan perangkat keras yang asli

Pada Desember 2023, [insiden rantai pasok Ledger Connect Kit](https://www.ledger.com/blog/security-incident-report) menyuntikkan kode berbahaya ke dApp yang memuat paket yang telah disusupi. Menurut Ledger, kode tersebut mengecoh pengguna EVM agar menandatangani transaksi penguras dana. Perangkat keras tidak secara spontan mengungkapkan seed-nya; sistem di sekelilingnya menyajikan maksud berbahaya kepada penanda tangan yang sah.

Kelas kegagalan ini menunjukkan mengapa “kunci tidak pernah meninggalkan perangkat” merupakan syarat yang perlu, tetapi tidak memadai. Kunci yang aman dapat dengan patuh mengotorisasi transaksi yang salah ketika pengguna, host, atau layar tidak dapat memahami secara andal apa yang sedang ditandatangani. Penguraian transaksi yang jelas, layar yang tepercaya, izin yang sempit, kontrol dependensi, dan ketahanan terhadap penandatanganan buta merupakan bagian dari keamanan kustodi.

### 3. Firmware berbahaya yang membocorkan rahasia melalui tanda tangan normal

Para peneliti Block telah [menerbitkan serangan riset praktis](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) yang membuat firmware dompet yang telah disusupi mengodekan materi rahasia secara terselubung ke dalam tanda tangan yang tampak normal. Model ancaman mereka mengasumsikan penyusupan firmware melalui jalur seperti pelanggaran rantai pasok, tindakan orang dalam, penyusupan sistem build, atau penyusupan kunci penandatanganan. Air gap tidak membantu jika transaksi bertanda tangan itu sendiri menjadi saluran eksfiltrasi.

Di sinilah build reprodusibel, beberapa pembuat build independen, dependensi yang dipatok, secure boot, dan keberagaman multisignature menjadi bermakna. Semua itu menangani mata rantai tertentu. Semua itu tidak serta-merta menyertifikasi desain, sumber, atau operator.

### 4. Paparan cadangan, substitusi alamat, dan pemaksaan

Banyak pencurian nyata sama sekali tidak mengeksploitasi silikon. Penyerang mencuri atau memotret cadangan seed, mengganti alamat penerima, menyamar sebagai dukungan pelanggan, menyusupi proses pembelian atau pengiriman, memperoleh perangkat beserta PIN yang lemah, atau memaksa pemilik untuk bekerja sama. Frasa pemulihan tetap merupakan kredensial induk portabel berdasarkan desainnya: siapa pun yang mendapatkannya dapat memulihkan dompet di tempat lain, terlepas dari keberadaan perangkat aslinya.

## Mengapa kompleksitas yang lebih besar dapat memperburuk keamanan

Kompleksitas terkadang beralasan. Layar terpisah dapat membuat peninjauan transaksi lebih tepercaya. Secure element dapat meningkatkan biaya ekstraksi fisik. Multisignature dapat menghilangkan satu kunci sebagai titik kegagalan tunggal. Namun, setiap mekanisme tambahan juga menciptakan antarmuka, keadaan, jalur pembaruan, dependensi, prosedur pemulihan, dan asumsi. Pertanyaan yang benar bukan “Apakah ini kompleks?” melainkan “Ancaman mana yang dikendalikan oleh setiap komponen, dan mode kegagalan baru apa yang diperkenalkannya?”

Prinsip klasik Saltzer dan Schroeder tentang [ekonomi mekanisme](https://www.ojp.gov/ncjrs/virtual-library/abstracts/protection-information-computer-systems) menyatakan bahwa desain perlindungan harus dibuat sesederhana dan sekecil mungkin agar pemeriksaan dan pemahaman tetap layak dilakukan. [Panduan keamanan sistem NIST](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-160v2r1.pdf) modern pun memperlakukan pengurangan permukaan serangan dan komponen multifungsi besar yang sulit dianalisis sebagai persoalan arsitektur. Kesederhanaan bukanlah ketiadaan kontrol. Kesederhanaan adalah penolakan untuk menambahkan kontrol yang perilakunya tidak dapat dijelaskan, diuji, dan dioperasikan dengan benar.

- 

Lebih banyak kode menciptakan lebih banyak potensi cacat. Hal itu juga membuat peninjauan menyeluruh lebih mahal dan interaksi lebih sulit dianalisis secara logis.

- 

Lebih banyak mode menciptakan risiko konfigurasi. Firmware Standard versus Edge, beragam alur kerja seed, dompet ber-passphrase, jalur USB dan air gap, serta variasi cadangan masing-masing dapat aman secara terpisah, tetapi membingungkan ketika digabungkan.

- 

Lebih banyak antarmuka menciptakan risiko translasi. Layar perangkat keras, aplikasi host, format QR, alur kerja microSD, konektor peramban, dan backend jaringan harus bersepakat secara tepat tentang apa yang diotorisasi pengguna.

- 

Lebih banyak seremoni dapat menurunkan kepatuhan. Jika jalur yang aman sulit ditempuh, orang akan melewatkan verifikasi, menunda pembaruan, menggunakan kembali cadangan, atau mengikuti petunjuk darurat tanpa memahaminya.

- 

Keyakinan yang lebih besar dapat memperbesar kerugian. Produk yang dipasarkan sebagai “cold”, “air-gapped”, atau “tidak dapat diretas” dapat mendorong pengguna memusatkan lebih banyak nilai di balik satu seed. Pemusatan mengubah satu cacat tersembunyi menjadi dampak katastrofik.

Pertahanan berlapis bernilai ketika lapisan-lapisannya independen. Pengulangan implementasi yang sama, sumber entropi yang sama, vendor yang sama, atau rahasia pemulihan yang sama bukanlah pertahanan independen.

## Sumber terbuka, audit, build reprodusibel, dan tinjauan AI bukanlah sinonim

Rekam jejak Coldcard sangat instruktif karena firmware-nya tersedia untuk umum dan dokumentasi build reprodusibel telah ada, sementara jalur rentan tetap berada dalam rilis selama bertahun-tahun. Hal itu tidak menjadikan keterbukaan sia-sia. Hal itu menunjukkan bahwa ketersediaan bukti dan pemeriksaan nyata atas properti yang tepat merupakan dua hal berbeda.

- 

Sumber terbuka berarti pihak luar dapat memeriksa implementasinya. Hal itu tidak membuktikan bahwa ada pihak yang meninjau setiap jalur kritis bagi keamanan atau bahwa pohon kode publik menghasilkan biner yang terpasang.

- 

Audit independen merupakan keterlibatan dengan ruang lingkup terbatas. Nilainya bergantung pada peninjau yang disebutkan, commit atau versi yang tepat, model ancaman, properti yang diuji, pengecualian, temuan, dan bukti perbaikan. “Telah diaudit” tanpa ruang lingkup hanyalah slogan.

- 

Build reprodusibel memungkinkan pihak independen mengikuti resep build yang dipublikasikan dan membandingkan hasilnya. Kecocokan dapat menghubungkan sumber dengan artefak rilis; kecocokan itu tidak membuktikan bahwa sumber tersebut benar.

- 

Peninjauan App Store dan penandatanganan kode menetapkan kontrol distribusi dan platform. Dengan sendirinya, keduanya tidak membuktikan bahwa suatu biner App Store setara bit demi bit dengan repositori publik.

- 

Tinjauan berbantuan AI dapat menelusuri basis kode yang besar, menghasilkan hipotesis adversarial, membandingkan invarian, dan mempercepat analisis manusia. Model juga dapat melewatkan konteks, menerima premis yang salah, atau menghasilkan temuan yang tampak masuk akal tetapi keliru. Tinjauan AI merupakan sudut pandang tambahan, bukan otoritas sertifikasi.

Halaman status Coldcard saat ini memberi contoh baik tentang bahasa ruang lingkup: halaman itu menyebut instrumentasi RNG perangkat nyata yang tertarget, peninjauan sumber, peninjauan hotfix, serta build reprodusibel beserta penelusuran jalur dadu; kemudian secara eksplisit menyatakan bahwa pemeriksaan tersebut bukan audit lengkap atas setiap biner firmware dan tidak menjamin ketiadaan cacat. Kalimat itu lebih bernilai daripada lencana tanpa kualifikasi.

## Apa yang secara jujur dapat diklaim Oath

Oath dibangun dengan arsitektur kustodi yang berbeda: aplikasi iPhone dan iPad dengan kode sumber tersedia, bukan penanda tangan perangkat keras khusus. [Repositori publiknya](https://github.com/devdasx/oath-wallet) menyediakan akses ke klien seluler dan petunjuk build di bawah lisensi MIT. [Model keamanan yang dipublikasikan](https://oathwallet.org/data/security-model.json) menyatakan bahwa rahasia dompet disimpan melalui iOS Keychain dengan cakupan aplikasi dan perlindungan yang hanya berlaku pada perangkat ini, sedangkan basis data lokal menyimpan referensi opak, bukan frasa pemulihan atau kunci privat. Transaksi dibuat dan ditandatangani pada perangkat sebelum data bertanda tangan dikirim ke infrastruktur jaringan.

Dokumentasi Apple mengenai [keamanan platform](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) menjelaskan penandatanganan kode wajib, pengembang yang teridentifikasi, peninjauan App Store otomatis dan oleh manusia, sandboxing, serta penegakan tanda tangan saat runtime. Dokumentasi [Keychain](https://support.apple.com/guide/security/secb0694df1a/1/web/1) menjelaskan perlindungan per item dan keterlibatan Secure Enclave dalam penanganan kunci Keychain. Semua itu merupakan kontrol platform yang nyata. Namun, semua itu bukan klaim bahwa kunci privat blockchain Oath sendiri adalah kunci Secure Enclave, dan Oath tidak membuat klaim tersebut.

Oath juga sengaja mempersempit permukaan produknya. Oath tidak mengoperasikan akun kustodial atau salinan pemulihan yang dipegang perusahaan, dan desain intinya menghindari perubahan dompet menjadi meja jual/beli, mesin swap, atau peramban serbaguna di dalam dompet. Versi 2.40.12 menambahkan pemeriksaan kesehatan keacakan fisik untuk mendeteksi pengulangan ekstrem, dominasi, dan siklus yang dapat diprediksi ketika pengguna membangun entropi dari dadu, lemparan koin, atau digit. Pemeriksaan tersebut dapat mendeteksi pola kegagalan yang jelas; pemeriksaan itu tidak dapat membuktikan bahwa suatu proses fisik berlangsung adil atau privat.

### Dapatkah Oath lebih aman daripada dompet perangkat keras?

Untuk sejumlah model ancaman, ya. Sebagai klaim universal, tidak. Dompet ponsel dapat menghindari jalur manufaktur dan pengiriman perangkat khusus, mengurangi jumlah benda yang secara kasatmata menandakan kustodi bernilai tinggi, menggunakan platform dengan pembaruan bertanda tangan yang cepat dan sandboxing matang, serta menempatkan implementasi yang dapat diperiksa dalam antarmuka familier yang lebih mungkin dioperasikan dengan benar oleh pengguna. Permukaan fitur yang lebih kecil juga dapat meniadakan seluruh kelas risiko peramban, swap, persetujuan, dan translasi lintas perangkat.

Untuk model ancaman lain, penanda tangan terpisah yang dirancang dengan baik merupakan batas yang penting. Jika sistem operasi ponsel atau proses dompet disusupi, pemisahan fisik dan layar yang dapat dipercaya secara independen dapat mencegah host berjaringan memperoleh atau menyalahgunakan kunci. Untuk nilai institusional atau nilai yang dapat mengubah kehidupan, arsitektur yang lebih kuat mungkin berupa kebijakan multisignature yang diuji dengan cermat menggunakan implementasi independen, entropi independen, lokasi terpisah, dan pemulihan terdokumentasi—bukan pertandingan antara satu ponsel dan satu kotak perangkat keras.

Karena itu, kata “hardware” tidak boleh mengakhiri analisis. iPhone juga merupakan perangkat keras. Perbedaan yang relevan adalah kode mana yang dieksekusi, bagaimana kode tersebut dibuat dan didistribusikan, di mana rahasia tersedia, apa yang dapat diverifikasi pengguna, bagaimana transaksi ditampilkan, bagaimana pembaruan berlangsung, dan kegagalan tunggal mana yang dapat memindahkan dana.

### Batas bukti juga penting bagi Oath

Situs web Oath saat ini menyatakan bahwa aplikasi tersebut diaudit secara independen dan dibuat secara reprodusibel. [Registri audit publiknya](https://oathwallet.org/security) ditetapkan sebagai tempat kanonis bagi nama peninjau, ruang lingkup yang tepat, tanggal, versi yang ditinjau, laporan, temuan, perbaikan, hash, dan materi reprodusibilitas. Pada saat publikasi, registri itu belum menampilkan artefak konkret tersebut. Repositori GitHub publiknya juga belum memiliki artefak rilis yang dapat digunakan untuk mereproduksi secara independen kecocokan dengan biner App Store.

Karena itu, artikel ini tidak mengklaim bahwa “setiap baris dalam biner App Store telah terbukti aman”, bahwa beberapa perusahaan telah menyertifikasi setiap perilaku, atau bahwa AI telah memverifikasi seluruh aplikasi. Pernyataan-pernyataan tersebut akan melampaui bukti publik yang tersedia. Pembedaan yang benar secara teknis ialah bahwa kode sumber dipublikasikan di GitHub, sedangkan Apple mendistribusikan biner terkompilasi yang ditandatangani melalui App Store. Menghubungkan keduanya memerlukan resep build publik, revisi sumber yang tidak dapat diubah, penguncian dependensi, salinan artefak App Store yang diperoleh, prosedur normalisasi untuk efek penandatanganan Apple, hasil yang cocok, dan atestasi independen.

Verifikasi paling kuat ketika sebuah klaim menyertakan bukti yang cukup agar orang asing yang skeptis dapat mereproduksinya. Oath harus dinilai dengan standar itu setegas vendor dompet perangkat keras mana pun.

## Apa yang seharusnya termuat dalam paket verifikasi setingkat universitas

Bagi peneliti, auditor, jurnalis, dan evaluator institusional, klaim keamanan dompet yang kredibel seharusnya berupa rantai bukti yang dapat ditelusuri, bukan dinding lencana. Setidaknya, mintalah:

- 

Model ancaman yang presisi. Sebutkan penyusupan jarak jauh, ekstraksi fisik, pembaruan berbahaya, penyusupan sistem build, entropi lemah, substitusi transaksi, pencurian cadangan, pemaksaan, dan ketersediaan secara terpisah.

- 

Revisi hasil tinjauan yang tidak dapat diubah. Identifikasi commit, graf dependensi, versi kompiler dan SDK, flag build, entitlement, serta konfigurasi yang termasuk dalam ruang lingkup.

- 

Laporan independen dengan identitas peninjau yang jelas. Publikasikan identitas peninjau, metodologi, tanggal, pengecualian, kriteria tingkat keparahan, temuan, dan bukti yang digunakan untuk menuntaskan setiap perbaikan.

- 

Reprodusibilitas dari sumber ke biner. Sediakan resep lengkap dan hasil build independen yang terikat pada rilis publik yang tepat. Jelaskan setiap perbedaan nondeterministik atau perbedaan yang dihasilkan oleh penandatanganan.

- 

Bukti jalur entropi. Uji sumbernya pada perangkat keras nyata, verifikasi perilaku kegagalan, tolak fallback senyap, dan telusuri jalur tepat yang digunakan oleh build rilis. Pengujian statistik terhadap output saja tidak dapat membuktikan bahwa generator dirangkai dengan benar.

- 

Pengujian transaksi adversarial. Uji substitusi penerima, manipulasi biaya, metadata berbahaya, batas penandatanganan buta, penyiaran transaksi yang terputus, dan perbedaan hasil parser antara setiap layar dan penanda tangan.

- 

Latihan pemulihan dan pembaruan. Uji petunjuk dalam tekanan waktu yang realistis, termasuk dengan informasi parsial, versi lama, migrasi, perangkat hilang, dan kemungkinan bahwa pembaruan tidak dapat memperbaiki rahasia yang sudah ada.

- 

Peninjauan berkelanjutan dan beragam. Gunakan pengujian deterministik, analisis statis, spesialis manusia, fuzzing, pengujian perangkat nyata, dan tinjauan berbantuan AI sebagai metode yang saling melengkapi. Catat apa yang ditetapkan dan tidak ditetapkan oleh setiap metode.

## Ancaman dapat melampaui layar

Swasimpan dapat meniadakan kustodian, tetapi juga dapat menjadikan seseorang sebagai batas otorisasi terakhir. Pencuri yang tidak dapat mematahkan kriptografi mungkin justru menyasar pemilik, keluarga, rumah, tempat kerja, atau identitas publik. Perangkat keras khusus terkadang dapat mempermudah penargetan tersebut karena secara kasatmata menunjukkan bahwa seseorang menangani sendiri aset bernilai, atau karena menciptakan benda fisik yang diperkirakan akan ditemukan penyerang. Ponsel juga dapat mengungkap kepemilikan jika saldo terlihat. Tak satu pun faktor bentuk menyelesaikan masalah pemaksaan.

Sebuah studi 2024 yang ditelaah sejawat, [“Menyelidiki Serangan Kunci Inggris: Serangan Fisik yang Menargetkan Pengguna Mata Uang Kripto”](https://doi.org/10.4230/LIPIcs.AFT.2024.10), menganalisis wawancara, forum, dan 146 artikel berita. Dataset berita yang telah disaring memuat 105 insiden serangan fisik, termasuk 24 penculikan dan 6 pembunuhan sebagai tindakan dominan yang dilaporkan. Para penulis menekankan masalah kurangnya pelaporan dan menemukan bahwa praktisi keamanan berpengalaman pun tidak kebal. Angka-angka ini menggambarkan dataset studi tersebut, bukan tingkat kejadian di seluruh dunia dan bukan bukti bahwa jenis dompet tertentu menyebabkan setiap kejahatan.

Bahaya tersebut bukan sekadar teori. Pada 2024, [Departemen Kehakiman Amerika Serikat](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) menguraikan vonis dalam sebuah konspirasi yang menggunakan pengintaian, invasi rumah, penculikan, penyerangan, dan ancaman untuk memaksa korban menguras akun mata uang kripto. Pelajarannya bukan untuk panik atau menjauh dari bantuan yang sah. Pelajarannya ialah memperlakukan privasi operasional dan keselamatan pribadi sebagai bagian dari desain dompet.

### Keselamatan manusia lebih utama daripada pemulihan aset

- 

Jangan mengumbar saldo atau rincian penyimpanan. Alamat publik, tangkapan layar, percakapan konferensi, unggahan media sosial, catatan pengiriman, dan kemasan yang dibuang dapat menghubungkan identitas, lokasi, serta perkiraan kekayaan.

- 

Pisahkan dana sehari-hari dari cadangan. Dompet untuk pengeluaran sehari-hari seharusnya tidak mengungkap atau mengendalikan seluruh posisi jangka panjang. Hindari memusatkan setiap aset dan jalur pemulihan di balik satu rahasia yang dapat segera diakses.

- 

Gunakan otorisasi independen untuk nilai yang signifikan. Multisignature yang dirancang dengan baik dapat mencegah satu perangkat curian atau satu lokasi yang berada di bawah pemaksaan menjadi cukup untuk mengakses dana, tetapi hanya jika kunci, implementasi, dan materi pemulihan benar-benar dipisahkan.

- 

Lindungi apa yang diungkapkan antarmuka. Gunakan kontrol kunci aplikasi dan privasi pengalih aplikasi, hindari menampilkan seluruh saldo di tempat umum, dan verifikasi penerima tanpa mengungkap kepemilikan lain yang tidak terkait.

- 

Susun rencana bersama profesional lokal yang berkualifikasi. Individu dan institusi berisiko tinggi seharusnya menyusun prosedur keamanan fisik, perjalanan, respons insiden, waris, dan keselamatan keluarga yang sesuai hukum bersama pakar yang memahami yurisdiksi dan keadaan pribadi mereka.

- 

Jangan pernah mempertaruhkan nyawa demi sebuah dompet. Tidak ada frasa pemulihan, perangkat, transaksi, atau jumlah dana yang sebanding dengan cedera fisik. Dalam ancaman seketika, utamakan keselamatan manusia dan hubungi layanan darurat setempat ketika sudah aman untuk melakukannya.

## Pelajarannya adalah bukti, bukan loyalitas kesukuan

Kegagalan Coldcard tidak membuktikan bahwa setiap Coldcard yang ada saat ini tidak aman, setiap dompet perangkat keras hanyalah sandiwara, atau setiap dompet ponsel lebih unggul. Coinkite telah menerbitkan rilis yang diperbaiki, panduan migrasi, validasi independen tertarget, dan batas eksplisit mengenai apa yang dibuktikan oleh pemeriksaan tersebut. Analisis yang bertanggung jawab harus mengakui baik tingkat keparahan insiden maupun rekam jejak perbaikannya.

Demikian pula, Oath tidak seharusnya begitu saja mewarisi kepercayaan hanya karena mengkritik arsitektur lain. Kode sumber publiknya, model kustodi yang sempit, kontrol platform Apple, penandatanganan lokal, dan kemudahan untuk ditinjau merupakan hal bermakna. Semua itu menjadi lebih kuat ketika pihak ketiga yang identitasnya disebutkan menerbitkan ruang lingkup dan temuan, ketika peneliti dapat mereproduksi biner yang didistribusikan dari sumber yang tidak dapat diubah, dan ketika tinjauan berbantuan AI dipadukan dengan pengujian deterministik serta pertimbangan manusia yang akuntabel.

Kesimpulan yang bertahan lebih sederhana: keamanan bukanlah bahan pembentuk kotaknya; keamanan adalah mutu rahasia, perilaku sistem secara keseluruhan, independensi pertahanannya, kejelasan antarmukanya, dan bukti yang tersedia untuk memverifikasi setiap klaim penting. Kompleksitas mungkin diperlukan, tetapi keberadaannya harus dibenarkan oleh satu ancaman terkendali pada satu waktu.

Lanjutkan dengan panduan Oath tentang [Create your first wallet](https://help.oathwallet.org/articles/create-wallet), [passphrase BIP39](https://oathwallet.org/articles/add-bip39-passphrase-oath-wallet), [model keamanan swasimpan](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model), serta [kode sandi aplikasi dan kontrol privasi](https://oathwallet.org/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy).

## Sumber primer dan teknis

- 

[Coinkite: imbauan keamanan Coldcard](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) — versi terdampak, cakupan entropi, rilis perbaikan, dan panduan migrasi.

- 

[Coldcard: status keamanan terkini](https://coldcard.com/security/status) — rilis terkini, cakupan validasi independen, batasan, dan status laporan pascainsiden.

- 

[TRM Labs: asesmen on-chain 5 Agustus](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) — estimasi kerugian bertanggal dan analisis aliran transaksi.

- 

[Kraken Security Labs: pengungkapan injeksi gangguan Trezor](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) — ekstraksi seed dengan akses fisik dan mitigasi menggunakan passphrase.

- 

[Ledger: laporan insiden Connect Kit](https://www.ledger.com/blog/security-incident-report) — penerbitan dependensi berbahaya dan dampaknya pada penandatanganan pengguna.

- 

[Block: riset pintu belakang firmware](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) — eksfiltrasi rahasia melalui tanda tangan dan mitigasi rantai pasok.

- 

[Keamanan Platform Apple: keamanan aplikasi dan penandatanganan kode](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) — distribusi iOS, sandboxing, dan kontrol integritas runtime.

- 

[Ordekian, Atondo-Siu, Hutchings, dan Vasek: studi serangan kunci Inggris](https://doi.org/10.4230/LIPIcs.AFT.2024.10) — analisis keamanan fisik yang ditelaah sejawat.

- 

[Departemen Kehakiman AS: vonis terkait invasi rumah untuk mencuri mata uang kripto](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) — pemaksaan fisik dan pengintaian yang terdokumentasi.

Oath tidak berafiliasi dengan dan tidak mendapat dukungan dari Coldcard, Coinkite, Trezor, Kraken, Ledger, Block, maupun para peneliti yang dikutip. Nama produk dan perusahaan merupakan milik pemiliknya masing-masing. Artikel ini merupakan edukasi keamanan, bukan nasihat keuangan, hukum, atau kedaruratan yang disesuaikan bagi individu. Jangan pernah memberikan frasa pemulihan, kunci privat, passphrase dompet, kode sandi aplikasi, atau kata sandi cadangan kepada situs web, agen dukungan, peneliti, maupun asisten AI.
