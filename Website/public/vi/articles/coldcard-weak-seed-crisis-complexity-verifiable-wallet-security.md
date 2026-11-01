# Khủng hoảng seed yếu của Coldcard: Phức tạp không đồng nghĩa với bảo mật

Oath Research · September 3, 2026

https://oathwallet.org/vi/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security

Trong sự cố Coldcard năm 2026, các thiết bị không hề bị xâm nhập từ xa. Sự cố ấy phơi bày một vấn đề căn bản hơn: lớp vỏ tinh vi không thể bảo vệ một seed vốn đã có thể dự đoán ngay từ khi ra đời.

Ghi chú nghiên cứu, ngày 3 tháng 9 năm 2026. Bài viết này phân biệt các sự kiện đã được xác nhận, tuyên bố của nhà cung cấp, ước tính on-chain và phân tích riêng của chúng tôi. Báo cáo kỹ thuật hậu kiểm chính thức của Coinkite vẫn chưa được công bố khi bài viết này được biên soạn. Tổng thiệt hại thay đổi khi các nhà điều tra xác định thêm những giao dịch thuộc vụ việc, vì vậy các số liệu dưới đây chỉ ghi nhận tình hình tại những thời điểm cụ thể, chứ không phải bản tổng kết cuối cùng.

Tháng 7 năm 2026, Bitcoin biến mất khỏi hàng nghìn địa chỉ mà chủ sở hữu tin rằng khóa của họ được ví phần cứng Coldcard bảo vệ. Điều cần đính chính đầu tiên và quan trọng nhất cũng là điều hé lộ nhiều nhất: các thiết bị không hề bị chiếm quyền từ xa. Một lỗi firmware đã làm suy yếu tính ngẫu nhiên được dùng khi một số ví được tạo. Kẻ tấn công có thể tìm kiếm trong không gian khóa đã bị thu hẹp ở nơi khác, khôi phục những khóa riêng khả dĩ, đối chiếu địa chỉ dẫn xuất với blockchain Bitcoin công khai và chi tiêu số tiền tương ứng mà không cần chạm vào phần cứng.

Một két sắt có thể cực kỳ kiên cố về mặt vật lý mà vẫn thất bại nếu bí mật đặt bên trong nó đã có thể dự đoán ngay từ đầu.

Đó là lý do sự cố này có ý nghĩa vượt xa phạm vi của một nhà cung cấp. Nó thách thức một phép giản lược dễ tạo cảm giác yên tâm: phần cứng đồng nghĩa với an toàn, nhiều thành phần hơn đồng nghĩa với bảo vệ tốt hơn, và danh sách tính năng dài đồng nghĩa với độ bảo đảm cao. Không tuyên bố nào trong số đó là một mô hình đe dọa. Bảo mật đến từ toàn bộ hệ thống—entropy, firmware, phần cứng, quy trình dựng, phân phối, giao diện, bản sao lưu, hành vi của người vận hành và an toàn thể chất—cũng như từ bằng chứng cho phép người ngoài kiểm nghiệm các tuyên bố của hệ thống.

## Điều gì đã xảy ra với Coldcard

Theo [khuyến cáo chính thức](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) của Coinkite, firmware bị ảnh hưởng đã sử dụng một luồng tạo seed có lỗi. Các seed ví được tạo trên firmware Mk2 hoặc Mk3 từ phiên bản 4.0.1 đến 4.1.9 có nguy cơ bị ảnh hưởng, trừ khi người dùng đã bổ sung đủ entropy từ xúc xắc theo cách riêng tư và độc lập, hoặc một passphrase BIP39 mạnh và duy nhất đã tạo thêm một rào cản. Khuyến cáo cũng bao gồm các seed được tạo trên thiết bị Mk4, Mk5 và Q trước những bản phát hành Standard hoặc Edge đã khắc phục lỗi. Với các thiết bị đời sau này, Coinkite báo cáo entropy vào khoảng 72 bit thay vì 128 bit như dự kiến.

Lỗi bắt nguồn từ firmware phát hành tháng 3 năm 2021 và âm thầm tồn tại trong nhiều năm. Cơ chế bảo vệ phần cứng vẫn hoạt động trên bí mật được cung cấp; vấn đề là quá trình tạo bí mật không tạo ra mức bất định như kỳ vọng. Khi kẻ tấn công có thể liệt kê các seed khả dĩ với chi phí khả thi, blockchain công khai trở thành một phép thử thuộc tập hoàn hảo: dẫn xuất địa chỉ, kiểm tra xem địa chỉ có tiền hay không và ký bằng bất kỳ khóa nào khôi phục được. Không cần lời nhắc lừa đảo, phiên USB, kiện hàng bị đánh cắp hay quyền truy cập vật lý.

### Vì sao entropy yếu gây hậu quả thảm khốc

Một seed ví không an toàn chỉ vì trông ngẫu nhiên đối với con người. Nó chỉ an toàn khi không đối thủ nào có thể phân biệt hoặc liệt kê các khả năng tiềm ẩn với chi phí khả thi. Mỗi bit entropy làm không gian tìm kiếm tăng gấp đôi. Giảm từ 128 bit xuống 72 bit không khiến seed chỉ “yếu hơn một chút”; nó loại bỏ 56 lần nhân đôi khối lượng công việc. Một không gian tìm kiếm hiệu dụng còn nhỏ hơn nữa có thể biến một phép tìm kiếm bất khả thi ở quy mô thiên văn thành một dự án kỹ thuật.

Các từ khôi phục vẫn hợp lệ về cú pháp. Các địa chỉ trông hoàn toàn bình thường. Phần cứng vẫn ký như thường lệ. Bản sao lưu vẫn khôi phục đúng. Đây là một thất bại âm thầm: mọi nghi thức hữu hình đều có thể thành công trong khi tiền đề bảo mật đã sụp đổ. Chính vì vậy, việc sinh số ngẫu nhiên cần có các kiểm thử tất định đối với cách kết nối, hoạt động đo kiểm nguồn entropy trên thiết bị thật và bằng chứng phát hành nối mã nguồn đã được rà soát với firmware được phân phối.

### Vụ trộm diễn ra theo nhiều đợt

Ngày 30 tháng 7, đợt quét tiền đầu tiên được báo cáo đã chuyển khoảng 594 BTC khỏi khoảng 500 địa chỉ trong chừng 25 phút. Các phân tích quy kết về sau đã mở rộng phạm vi được xác định của sự cố. Một [đánh giá của TRM Labs công bố ngày 5 tháng 8](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) mô tả số liệu cộng dồn tại thời điểm đó là gần 1,816 BTC—tương đương khoảng 116 triệu USD—từ hơn 5,200 địa chỉ qua bốn đợt. Các nhà điều tra khác sử dụng quy tắc xác nhận khác và về sau báo cáo tổng số chênh lệch đôi chút. Vì thế, nên đọc các con số này như bằng chứng về quy mô, chứ không phải một bản tổng kết cuối cùng đã được thống nhất.

Trang [trạng thái bảo mật hiện tại](https://coldcard.com/security/status) của Coinkite nói rõ rằng báo cáo hậu kiểm chính thức vẫn đang được thực hiện và không tuyên bố từng khoản tổn thất được báo cáo đều đã được xác định là thuộc vụ việc. Sự bất định đó không phải là lý do để xem nhẹ sự cố. Đó là lý do phải duy trì ranh giới giữa cơ chế đã được xác minh, giao dịch quan sát được, kết quả quy kết từ phân tích và kết luận pháp chứng cuối cùng.

## Cập nhật firmware không sửa được một seed cũ

Đây là thực tế vận hành mà người dùng bị ảnh hưởng không thể bỏ qua. Firmware đã sửa lỗi sẽ khắc phục việc tạo seed trong tương lai; nó không thể bổ sung entropy hồi tố cho một seed đã tồn tại. Ví được khôi phục từ seed đó trên phần cứng mới vẫn nằm dưới quyền kiểm soát của chính bí mật dễ bị xâm phạm ấy. Thay lớp vỏ kim loại, cài ứng dụng di động hay chuyển các từ sang một thương hiệu khác đều không làm thay đổi khóa. Tiền phải được chuyển đến các địa chỉ dẫn xuất từ một seed mới được tạo và bảo vệ độc lập.

Theo kết quả xác minh ngày 3 tháng 9 năm 2026, trang trạng thái của Coldcard liệt kê Mk4/Mk5 Standard 5.6.1 và Q Standard 1.5.1Q là các bản phát hành Standard được khuyến nghị. Các phiên bản tối thiểu đã sửa lỗi là Mk2/Mk3 4.2.0 trở lên; Mk4/Mk5 Standard 5.6.0 trở lên; Q Standard 1.5.0Q trở lên; Mk4/Mk5 Edge 6.6.0X trở lên; và Q Edge 6.6.0QX trở lên. Kênh phát hành có ý nghĩa quan trọng: một phiên bản Edge có số hiệu cao hơn không đương nhiên tương đương với một bản phát hành Standard đã sửa lỗi.

### Nếu bạn có thể bị ảnh hưởng

- 

Ngừng dựa vào lớp vỏ thiết bị. Hãy xác định mẫu thiết bị, kênh phát hành, firmware được dùng khi seed được tạo và liệu ngoại lệ chính thức dành cho xúc xắc độc lập có áp dụng rõ ràng hay không. Nếu không chắc chắn, hãy coi seed là bị ảnh hưởng.

- 

Chỉ làm theo hướng dẫn chính thức. Hãy truy cập trực tiếp khuyến cáo và trang trạng thái bảo mật của Coldcard, xác minh chữ ký firmware cùng các giá trị băm được công bố, đồng thời từ chối mọi lời “hỗ trợ di chuyển” không được yêu cầu. Không bên hỗ trợ hợp pháp nào cần cụm từ khôi phục của bạn.

- 

Tạo một seed hoàn toàn mới trong môi trường đã khắc phục lỗi. Không chỉnh sửa, xáo trộn hay nối thêm từ vào cụm từ cũ. Ví mới cần entropy mới. Với số dư đáng kể, hãy cân nhắc một bản triển khai độc lập hoặc chính sách đa chữ ký được thiết kế đúng cách để luồng tạo seed của một nhà cung cấp không phải là gốc tin cậy duy nhất.

- 

Xác minh khả năng khôi phục trước khi nạp tiền. Ghi lại bản sao lưu một cách riêng tư, khôi phục nó trong quy trình có kiểm soát và xác nhận dấu vân tay công khai hoặc địa chỉ nhận dự kiến. Một bản sao lưu chưa từng được kiểm thử chỉ là một giả định.

- 

Chuyển một khoản nhỏ để thử, rồi mới chuyển phần còn lại. Xác minh đích đến và xác nhận giao dịch trước khi chuyển toàn bộ số dư. Tránh ứng biến vội vàng, nhưng đừng nhầm một quy trình bình tĩnh với sự cho phép trì hoãn xử lý một seed đã bị phơi lộ.

- 

Ngừng sử dụng seed cũ. Cập nhật firmware và thêm một passphrase mạnh về sau đều không sửa được seed đó. Hãy lưu các hồ sơ cần thiết cho mục đích thuế hoặc pháp lý mà không giữ lại những bản sao bí mật không cần thiết.

Coinkite cho biết ít nhất 50 lần gieo xúc xắc công bằng, độc lập và riêng tư trong quy trình Add Dice Rolls bị ảnh hưởng đã đóng góp ít nhất 128 bit chỉ từ xúc xắc; từ 99 lần trở lên đóng góp khoảng 256 bit. Các điều kiện chính xác có ý nghĩa quyết định. Nếu chuỗi kết quả đã bị ghi lại, bị quan sát, có thiên lệch, không độc lập hoặc không chắc chắn, đừng suy diễn độ an toàn chỉ từ số lần gieo. Một passphrase BIP39 mạnh đã tồn tại từ trước có thể tạo thêm rào cản, nhưng Coinkite vẫn khuyên di chuyển và không mô tả passphrase như một cách sửa seed.

## Thiết bị không bị hack—và đó mới là lời cảnh báo sâu xa hơn

Gọi mọi tổn thất là một “vụ hack ví phần cứng” sẽ nén nhiều lớp thất bại khác nhau vào một cụm từ giật gân. Điều đó che khuất những biện pháp kiểm soát có thể đã giúp ích. Trong sự cố Coldcard, kẻ tấn công không đánh bại lớp vỏ, bàn phím số, cơ chế kiểm soát USB hay phần tử bảo mật trong thiết bị của từng nạn nhân. Kẻ tấn công đi vòng qua thiết bị vì bí mật gốc có thể bị duyệt cạn.

Một ranh giới bảo mật chỉ bảo vệ những gì đi qua nó. Nếu khóa đi vào phần tử bảo mật là khóa yếu, nếu firmware độc hại làm rò rỉ khóa qua chữ ký, nếu màn hình hiển thị đích đến do kẻ tấn công kiểm soát, hoặc nếu một người bị cưỡng ép cho phép chuyển tiền, thì sự tồn tại của phần cứng chuyên dụng không hóa giải được cuộc tấn công.

## Tổn thất do ví phần cứng không phải lúc nào cũng giống nhau

Một số sự cố được ghi nhận và các minh chứng nghiên cứu cho thấy vì sao loại hình này cần được mô tả chính xác. Chúng không chứng minh ví phần cứng là vô dụng. Chúng cho thấy phần cứng chuyển rủi ro sang một hệ thống khác gồm chip, firmware, chuỗi cung ứng, phần mềm trên thiết bị chủ, giao thức ký, bản sao lưu và quy trình của con người.

### 1. Tiêm lỗi và trích xuất seed bằng truy cập vật lý

Năm 2020, [Kraken Security Labs đã công bố](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) một kỹ thuật làm nhiễu điện áp nhằm vào các thiết bị Trezor One và Model T. Kraken báo cáo rằng khoảng 15 phút tiếp cận vật lý có thể cho phép trích xuất vật liệu seed đã mã hóa, sau đó một mã PIN ngắn có thể bị dò bằng phương pháp vét cạn. Biện pháp giảm thiểu thực tế của họ là dùng một passphrase BIP39 mạnh không được lưu trên thiết bị. Kraken cũng ghi nhận một lớp tấn công tương tự nhằm vào KeepKey.

Đây là một mối đe dọa khác với Coldcard. Nó đòi hỏi phải có thiết bị mục tiêu trong tay và thực hiện kỹ thuật tiêm lỗi kiểu phòng thí nghiệm. Nó cho thấy khả năng chống can thiệp phụ thuộc vào vi điều khiển và thiết kế lưu trữ được chọn, đồng thời mã PIN không nhất thiết là một bí mật mã hóa có entropy cao.

### 2. Phần mềm bị xâm phạm quanh một thiết bị ký phần cứng chính hãng

Tháng 12 năm 2023, trong [sự cố chuỗi cung ứng Ledger Connect Kit](https://www.ledger.com/blog/security-incident-report), mã độc đã được chèn vào các dApp tải một gói bị xâm phạm. Theo Ledger, đoạn mã đã lừa người dùng EVM ký những giao dịch rút cạn tiền. Các thiết bị phần cứng không tự phát làm lộ seed; hệ thống bao quanh chúng đã đưa yêu cầu độc hại tới những người ký hợp lệ.

Lớp thất bại này cho thấy vì sao “khóa không bao giờ rời khỏi thiết bị” là điều cần thiết nhưng chưa đủ. Một khóa an toàn vẫn có thể thực hiện đúng chức năng nhưng lại cấp quyền cho giao dịch sai khi người dùng, thiết bị chủ hoặc màn hình không thể diễn giải đáng tin cậy nội dung đang được ký. Việc diễn giải giao dịch rõ ràng, màn hình đáng tin cậy, quyền hạn được thu hẹp, kiểm soát phần phụ thuộc và khả năng chống ký mù đều là thành phần của bảo mật lưu ký.

### 3. Firmware độc hại làm rò rỉ bí mật qua chữ ký thông thường

Các nhà nghiên cứu của Block đã [công bố một cuộc tấn công nghiên cứu có tính thực tiễn](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet), trong đó firmware ví đã bị xâm phạm âm thầm mã hóa vật liệu bí mật vào những chữ ký trông có vẻ bình thường. Mô hình đe dọa của họ giả định firmware bị xâm phạm qua các con đường như vi phạm chuỗi cung ứng, hành vi nội gián, xâm phạm hệ thống dựng hoặc xâm phạm khóa ký. Cơ chế air gap không giúp ích nếu chính giao dịch đã ký trở thành kênh rò rỉ dữ liệu.

Đây là nơi các bản dựng tái lập được, nhiều bên dựng độc lập, phần phụ thuộc được ghim phiên bản, khởi động an toàn và việc đa dạng hóa trong đa chữ ký trở nên có ý nghĩa. Chúng xử lý những mắt xích cụ thể trong một chuỗi. Chúng không mặc nhiên chứng nhận thiết kế, mã nguồn hay người vận hành.

### 4. Lộ bản sao lưu, thay thế địa chỉ và cưỡng ép

Nhiều vụ trộm thực tế không hề khai thác silicon. Kẻ tấn công đánh cắp hoặc chụp ảnh bản sao lưu seed, thay địa chỉ nhận, mạo danh bộ phận hỗ trợ, xâm phạm quy trình mua hàng hoặc vận chuyển, lấy được thiết bị cùng một mã PIN yếu, hoặc buộc chủ sở hữu hợp tác. Theo thiết kế, cụm từ khôi phục vẫn là thông tin xác thực cấp cao nhất có thể mang đi: bất kỳ ai có được nó đều có thể khôi phục ví ở nơi khác, bất kể thiết bị ban đầu ở đâu.

## Vì sao phức tạp hơn có thể làm bảo mật kém đi

Đôi khi độ phức tạp là có lý do. Một màn hình riêng có thể khiến việc rà soát giao dịch đáng tin cậy hơn. Phần tử bảo mật có thể làm tăng chi phí trích xuất vật lý. Đa chữ ký có thể loại bỏ một khóa đơn lẻ khỏi vai trò điểm thất bại duy nhất. Nhưng mỗi cơ chế bổ sung cũng tạo ra giao diện, trạng thái, lộ trình cập nhật, phần phụ thuộc, quy trình khôi phục và giả định. Câu hỏi đúng không phải là “Hệ thống này có phức tạp không?” mà là “Mỗi thành phần kiểm soát mối đe dọa nào, và nó đưa vào những chế độ thất bại mới nào?”

Nguyên tắc kinh điển của Saltzer và Schroeder về [tính tiết kiệm của cơ chế](https://www.ojp.gov/ncjrs/virtual-library/abstracts/protection-information-computer-systems) cho rằng thiết kế bảo vệ phải đơn giản và nhỏ gọn nhất có thể để việc kiểm tra và thấu hiểu vẫn khả thi. Tương tự, [hướng dẫn hiện đại của NIST về bảo mật hệ thống](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-160v2r1.pdf) cũng xem việc giảm bề mặt tấn công và các thành phần đa chức năng lớn, khó phân tích là những mối quan tâm ở cấp kiến trúc. Tính đơn giản không phải là thiếu biện pháp kiểm soát. Đó là sự từ chối bổ sung các biện pháp kiểm soát có hành vi không thể giải thích, kiểm thử và vận hành đúng.

- 

Càng nhiều mã, càng có nhiều khiếm khuyết khả dĩ. Điều đó cũng làm cho việc rà soát toàn diện tốn kém hơn và khiến tương tác giữa các thành phần khó suy luận hơn.

- 

Càng nhiều chế độ, rủi ro cấu hình càng lớn. Firmware Standard và Edge, nhiều quy trình tạo seed, ví dùng passphrase, quy trình qua USB và air gap, cùng các biến thể sao lưu có thể an toàn khi đứng riêng nhưng trở nên khó hiểu khi kết hợp.

- 

Càng nhiều giao diện, rủi ro sai lệch khi chuyển dịch càng lớn. Màn hình phần cứng, ứng dụng trên thiết bị chủ, định dạng QR, quy trình microSD, trình kết nối trình duyệt và hệ thống phụ trợ mạng phải diễn giải nhất quán, chính xác điều người dùng đang cho phép.

- 

Càng nhiều nghi thức, mức độ tuân thủ càng có thể giảm. Nếu quy trình an toàn quá khó, người dùng sẽ bỏ qua bước xác minh, trì hoãn cập nhật, tái sử dụng bản sao lưu hoặc làm theo hướng dẫn khẩn cấp mà không hiểu chúng.

- 

Càng tin tưởng, tổn thất càng có thể lớn. Một sản phẩm được tiếp thị là “lạnh”, “cách ly mạng” hoặc “không thể bị hack” có thể khuyến khích người dùng dồn lượng tài sản lớn hơn vào một seed duy nhất. Sự tập trung biến một khiếm khuyết ẩn thành hậu quả thảm khốc.

Phòng thủ theo chiều sâu có giá trị khi các lớp độc lập với nhau. Việc lặp lại cùng một bản triển khai, cùng một nguồn entropy, cùng một nhà cung cấp hoặc cùng một bí mật khôi phục không phải là phòng thủ độc lập.

## Mã nguồn mở, kiểm toán, bản dựng tái lập được và rà soát bằng AI không đồng nghĩa với nhau

Hồ sơ của Coldcard đặc biệt giàu tính chỉ dẫn vì firmware của hãng đã được công khai và tài liệu về bản dựng tái lập được đã tồn tại, trong khi luồng dễ bị tổn thương vẫn nằm trong các bản phát hành suốt nhiều năm. Điều đó không khiến tính cởi mở trở nên vô dụng. Nó cho thấy việc bằng chứng sẵn có và việc thực sự kiểm tra đúng thuộc tính là hai điều khác nhau.

- 

Mã nguồn mở có nghĩa là người ngoài có thể kiểm tra bản triển khai. Điều đó không xác lập rằng đã có người rà soát mọi luồng trọng yếu về bảo mật hoặc rằng cây mã nguồn công khai đã tạo ra tệp nhị phân được cài đặt.

- 

Một cuộc kiểm toán độc lập là một nhiệm vụ có phạm vi giới hạn. Giá trị của nó phụ thuộc vào danh tính người rà soát, commit hoặc phiên bản chính xác, mô hình đe dọa, các thuộc tính được kiểm thử, phần loại trừ, phát hiện và bằng chứng khắc phục. Từ “đã kiểm toán” mà không có phạm vi chỉ là một khẩu hiệu.

- 

Một bản dựng tái lập được cho phép các bên dựng độc lập làm theo công thức đã công bố và so sánh đầu ra. Kết quả trùng khớp có thể nối mã nguồn với một gói phát hành; nó không chứng minh mã nguồn là đúng.

- 

Quy trình xét duyệt của cửa hàng ứng dụng và việc ký mã xác lập các biện pháp kiểm soát về phân phối và nền tảng. Tự thân chúng không chứng minh tệp nhị phân trên App Store tương đương từng bit với một kho mã nguồn công khai.

- 

Rà soát có AI hỗ trợ có thể tìm kiếm trong các cơ sở mã lớn, tạo giả thuyết đối kháng, so sánh các bất biến và đẩy nhanh phân tích của con người. Một mô hình cũng có thể bỏ sót ngữ cảnh, chấp nhận một tiền đề sai hoặc đưa ra một phát hiện nghe hợp lý nhưng không chính xác. Rà soát bằng AI là một lăng kính khác, không phải cơ quan chứng nhận.

Trang trạng thái hiện tại của Coldcard thể hiện cách diễn đạt phạm vi tốt: trang này nêu rõ hoạt động đo kiểm RNG có mục tiêu trên thiết bị thật, các cuộc rà soát mã nguồn, một cuộc rà soát bản sửa lỗi khẩn cấp, cùng một bản dựng tái lập được và kết quả truy vết luồng xúc xắc; sau đó nói rõ rằng các bước kiểm tra ấy không phải là cuộc kiểm toán toàn diện mọi tệp nhị phân firmware và không bảo đảm không có khiếm khuyết. Câu đó có giá trị hơn một huy hiệu không kèm điều kiện.

## Oath có thể tuyên bố trung thực những gì

Oath được xây dựng quanh một kiến trúc lưu ký khác: một ứng dụng iPhone và iPad có mã nguồn công khai để xem xét, thay vì một thiết bị ký phần cứng chuyên dụng. [Kho mã nguồn công khai](https://github.com/devdasx/oath-wallet) công khai mã ứng dụng di động và hướng dẫn dựng theo giấy phép MIT. [Mô hình bảo mật đã công bố](https://oathwallet.org/data/security-model.json) nêu rằng bí mật của ví được lưu qua iOS Keychain trong phạm vi ứng dụng với chế độ bảo vệ chỉ dành cho thiết bị này, trong khi cơ sở dữ liệu cục bộ chỉ giữ các tham chiếu không tiết lộ nội dung thay vì cụm từ khôi phục hay khóa riêng. Giao dịch được tạo và ký trên thiết bị trước khi dữ liệu đã ký được gửi đến hạ tầng mạng.

Tài liệu của Apple về [bảo mật nền tảng](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) mô tả việc bắt buộc ký mã, nhà phát triển được định danh, quy trình xét duyệt App Store tự động và do con người thực hiện, cơ chế sandbox và thực thi chữ ký khi chạy. [Tài liệu về Keychain](https://support.apple.com/guide/security/secb0694df1a/1/web/1) mô tả cơ chế bảo vệ theo từng mục và sự tham gia của Secure Enclave vào việc xử lý khóa Keychain. Đây là những biện pháp kiểm soát nền tảng có thật. Chúng không phải là tuyên bố rằng bản thân các khóa riêng blockchain của Oath là khóa Secure Enclave, và Oath không đưa ra tuyên bố đó.

### Oath có thể an toàn hơn ví phần cứng không?

Với một số mô hình đe dọa thì có. Xét như một tuyên bố phổ quát thì không. Ví trên điện thoại có thể tránh quy trình sản xuất và vận chuyển của một thiết bị chuyên dụng, giảm số đồ vật phát tín hiệu hữu hình rằng người dùng đang lưu ký tài sản có giá trị, tận dụng một nền tảng có cơ chế cập nhật nhanh, có ký và sandbox đã trưởng thành, đồng thời đưa một bản triển khai có thể kiểm tra vào giao diện quen thuộc mà người dùng có khả năng vận hành đúng hơn. Bề mặt tính năng nhỏ hơn cũng có thể loại bỏ toàn bộ các lớp rủi ro liên quan đến trình duyệt, hoán đổi, phê duyệt và chuyển dịch giữa thiết bị.

Với các mô hình đe dọa khác, một thiết bị ký riêng được thiết kế tốt là ranh giới quan trọng. Nếu hệ điều hành điện thoại hoặc tiến trình của ví bị xâm phạm, sự tách biệt vật lý và một màn hình đáng tin cậy độc lập có thể ngăn thiết bị chủ nối mạng lấy hoặc lạm dụng khóa. Với giá trị ở cấp tổ chức hoặc đủ làm thay đổi cuộc đời, kiến trúc mạnh hơn có thể là một chính sách đa chữ ký đã được kiểm thử cẩn thận, sử dụng các bản triển khai độc lập, entropy độc lập, địa điểm tách biệt và quy trình khôi phục được lập thành tài liệu—chứ không phải cuộc thi giữa một chiếc điện thoại và một hộp phần cứng.

Vì vậy, từ “phần cứng” không bao giờ nên khép lại quá trình phân tích. iPhone cũng là phần cứng. Những khác biệt liên quan là mã nào được thực thi, mã được dựng và phân phối ra sao, bí mật khả dụng ở đâu, người dùng có thể xác minh gì, giao dịch được hiển thị thế nào, cập nhật diễn ra ra sao và những thất bại đơn lẻ nào có thể khiến tiền bị chuyển đi.

### Ranh giới bằng chứng cũng quan trọng đối với Oath

Trang web của Oath hiện tuyên bố rằng ứng dụng đã được kiểm toán độc lập và được dựng theo cách có thể tái lập. [Sổ đăng ký kiểm toán công khai](https://oathwallet.org/security) được xác định là nguồn tham chiếu chính thức để công bố tên người rà soát, phạm vi chính xác, ngày tháng, phiên bản đã rà soát, báo cáo, phát hiện, biện pháp khắc phục, giá trị băm và tài liệu về khả năng tái lập. Tại thời điểm xuất bản, sổ đăng ký đó chưa hiển thị những tư liệu cụ thể này. Kho GitHub công khai cũng chưa có gói phát hành nào làm đối tượng tham chiếu để độc lập tái lập kết quả đối chiếu với tệp nhị phân trên App Store.

Do đó, bài viết này không tuyên bố rằng “mọi dòng trong tệp nhị phân trên App Store đã được chứng minh là an toàn”, rằng một số công ty đã chứng nhận mọi hành vi, hay rằng AI đã xác minh toàn bộ ứng dụng. Những tuyên bố đó sẽ vượt quá bằng chứng công khai hiện có. Sự phân biệt đúng về mặt kỹ thuật là mã nguồn được công bố trên GitHub, còn Apple phân phối một tệp nhị phân đã biên dịch và ký qua App Store. Việc nối hai phía này đòi hỏi công thức dựng công khai, bản sửa đổi mã nguồn bất biến, tệp khóa phần phụ thuộc, gói App Store đã được thu thập, quy trình chuẩn hóa các hiệu ứng do Apple ký, kết quả trùng khớp và chứng thực độc lập.

Hoạt động xác minh mạnh nhất khi một tuyên bố đi kèm đủ bằng chứng để một người ngoài có thái độ hoài nghi có thể tái lập kết quả. Oath phải được đánh giá theo tiêu chuẩn đó nghiêm ngặt như bất kỳ nhà cung cấp ví phần cứng nào.

## Một bộ hồ sơ xác minh đạt chuẩn đại học nên bao gồm những gì

Đối với nhà nghiên cứu, kiểm toán viên, nhà báo và các nhà đánh giá của tổ chức, một tuyên bố đáng tin cậy về bảo mật ví nên là một chuỗi bằng chứng có thể lần theo, thay vì một bức tường huy hiệu. Tối thiểu, hãy yêu cầu:

- 

Một mô hình đe dọa chính xác. Gọi tên riêng từng mối đe dọa: xâm phạm từ xa, trích xuất vật lý, cập nhật độc hại, xâm phạm hệ thống dựng, entropy yếu, thay thế giao dịch, đánh cắp bản sao lưu, cưỡng ép và tính khả dụng.

- 

Một bản sửa đổi bất biến đã được rà soát. Xác định commit, đồ thị phần phụ thuộc, phiên bản trình biên dịch và SDK, cờ dựng, entitlement và cấu hình nằm trong phạm vi.

- 

Một báo cáo độc lập nêu rõ danh tính. Công bố người rà soát, phương pháp, ngày tháng, phần loại trừ, tiêu chí mức độ nghiêm trọng, phát hiện và bằng chứng được dùng để xác nhận hoàn tất từng biện pháp khắc phục.

- 

Khả năng tái lập từ mã nguồn đến tệp nhị phân. Cung cấp công thức đầy đủ và kết quả dựng độc lập gắn với đúng bản phát hành công khai. Giải thích mọi khác biệt không tất định hoặc do quá trình ký tạo ra.

- 

Bằng chứng về luồng entropy. Kiểm thử nguồn trên phần cứng thật, xác minh hành vi khi lỗi, loại bỏ việc âm thầm chuyển sang phương án dự phòng và truy vết đúng luồng được bản dựng phát hành sử dụng. Chỉ riêng các phép kiểm thử thống kê đầu ra không thể chứng minh bộ sinh đã được kết nối đúng.

- 

Kiểm thử giao dịch đối kháng. Thử nghiệm việc thay thế người nhận, thao túng phí, siêu dữ liệu thù địch, ranh giới ký mù, phát sóng bị gián đoạn và sự bất đồng giữa các bộ phân tích cú pháp của từng màn hình và thiết bị ký.

- 

Diễn tập khôi phục và cập nhật. Kiểm thử hướng dẫn dưới áp lực thời gian thực tế, bao gồm thông tin không đầy đủ, phiên bản cũ, di chuyển, thiết bị thất lạc và khả năng một bản cập nhật không thể sửa các bí mật đã tồn tại.

- 

Rà soát liên tục và đa dạng. Sử dụng kiểm thử tất định, phân tích tĩnh, chuyên gia chuyên môn, kiểm thử fuzz, kiểm thử trên thiết bị thật và rà soát có AI hỗ trợ như các phương pháp bổ sung cho nhau. Ghi lại mỗi phương pháp đã xác lập và chưa xác lập được điều gì.

## Mối đe dọa có thể bước ra khỏi màn hình

Tự lưu ký có thể loại bỏ bên lưu ký, nhưng cũng có thể biến một con người thành ranh giới cấp quyền cuối cùng. Kẻ trộm không phá được mật mã có thể chuyển sang nhắm vào chủ sở hữu, gia đình, nhà ở, nơi làm việc hoặc danh tính công khai. Phần cứng chuyên dụng đôi khi có thể khiến việc nhắm mục tiêu dễ hơn vì nó để lộ rõ rằng một người đặc biệt coi trọng việc tự lưu ký hoặc tạo ra một vật thể mà kẻ tấn công kỳ vọng sẽ tìm thấy. Điện thoại cũng có thể làm lộ tài sản nắm giữ nếu số dư hiển thị. Không dạng thiết bị nào giải quyết được vấn đề cưỡng ép.

Một nghiên cứu được bình duyệt năm 2024, [“Điều tra các vụ tấn công bằng cờ lê: Tấn công vật lý nhắm vào người dùng tiền mã hóa”](https://doi.org/10.4230/LIPIcs.AFT.2024.10), đã phân tích các cuộc phỏng vấn, diễn đàn và 146 bài báo. Tập dữ liệu tin tức sau khi lọc của nghiên cứu gồm 105 sự cố tấn công vật lý, với hành vi chính được báo cáo gồm 24 vụ bắt cóc và 6 vụ giết người. Các tác giả nhấn mạnh tình trạng không được báo cáo đầy đủ và nhận thấy ngay cả những người hành nghề bảo mật giàu kinh nghiệm cũng không miễn nhiễm. Những con số này mô tả tập dữ liệu của nghiên cứu, không phải tần suất xảy ra trên toàn thế giới và cũng không chứng minh một loại ví cụ thể đã gây ra từng tội ác.

Mối nguy không chỉ là lý thuyết. Năm 2024, [Bộ Tư pháp Hoa Kỳ](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) mô tả các bản án trong một âm mưu sử dụng giám sát, đột nhập tư gia, bắt cóc, hành hung và đe dọa để buộc nạn nhân rút cạn tài khoản tiền mã hóa. Bài học không phải là hoảng loạn hay né tránh sự hỗ trợ chính đáng. Đó là phải xem quyền riêng tư trong vận hành và an toàn cá nhân như một phần của thiết kế ví.

### An toàn con người quan trọng hơn việc thu hồi tài sản

- 

Không phô bày số dư hoặc thông tin chi tiết về cách lưu trữ. Địa chỉ công khai, ảnh chụp màn hình, cuộc trò chuyện tại hội nghị, bài đăng mạng xã hội, hồ sơ vận chuyển và bao bì vứt bỏ có thể liên kết danh tính và địa điểm với mức độ giàu có mà người khác suy đoán.

- 

Tách tiền chi tiêu hằng ngày khỏi khoản dự trữ. Một ví chi tiêu không nên làm lộ hoặc kiểm soát toàn bộ danh mục tài sản dài hạn. Tránh tập trung mọi tài sản và phương án khôi phục sau một bí mật duy nhất có thể truy cập ngay lập tức.

- 

Sử dụng cơ chế cấp quyền độc lập cho tài sản có giá trị đáng kể. Một thiết kế đa chữ ký tốt có thể bảo đảm rằng chỉ một thiết bị bị đánh cắp hoặc việc cưỡng ép tại một địa điểm duy nhất vẫn chưa đủ, nhưng chỉ khi khóa, bản triển khai và thông tin khôi phục thực sự được tách biệt.

- 

Bảo vệ những gì giao diện làm lộ. Sử dụng khóa ứng dụng và biện pháp bảo vệ riêng tư trong trình chuyển đổi ứng dụng, tránh hiển thị toàn bộ số dư nơi công cộng và xác minh người nhận mà không để lộ những tài sản không liên quan.

- 

Lập kế hoạch cùng các chuyên gia địa phương đủ năng lực. Cá nhân và tổ chức có rủi ro cao nên xây dựng các quy trình hợp pháp về an ninh vật lý, đi lại, ứng phó sự cố, thừa kế và an toàn gia đình cùng những chuyên gia hiểu khu vực pháp lý và hoàn cảnh cá nhân của họ.

- 

Không bao giờ đánh đổi tính mạng vì một chiếc ví. Không cụm từ khôi phục, thiết bị, giao dịch hay số tiền nào đáng để đánh đổi bằng thương tích thân thể. Khi có đe dọa tức thời, hãy ưu tiên an toàn con người và liên hệ dịch vụ khẩn cấp địa phương khi có thể làm vậy một cách an toàn.

## Bài học nằm ở bằng chứng, không phải lòng trung thành phe phái

Thất bại của Coldcard không chứng minh rằng mọi Coldcard hiện nay đều không an toàn, mọi ví phần cứng chỉ là màn kịch, hay mọi ví trên điện thoại đều ưu việt hơn. Coinkite đã công bố các bản phát hành sửa lỗi, hướng dẫn di chuyển, hoạt động kiểm chứng độc lập có mục tiêu và các giới hạn rõ ràng đối với những gì các bước kiểm tra đó xác lập. Phân tích có trách nhiệm phải thừa nhận cả mức độ nghiêm trọng của sự cố lẫn hồ sơ khắc phục.

Tương tự, Oath không nên mặc nhiên được tin cậy chỉ vì phê phán một kiến trúc khác. Mã nguồn công khai, mô hình lưu ký thu hẹp, các biện pháp kiểm soát nền tảng của Apple, việc ký cục bộ và khả năng rà soát của ứng dụng đều có ý nghĩa. Chúng sẽ mạnh hơn khi một bên thứ ba có danh tính rõ ràng công bố phạm vi và phát hiện, khi các nhà nghiên cứu có thể tái lập tệp nhị phân được phân phối từ mã nguồn bất biến, và khi rà soát có AI hỗ trợ được kết hợp với kiểm thử tất định cùng phán đoán có trách nhiệm của con người.

Kết luận bền vững đơn giản hơn: bảo mật không nằm ở vật liệu của chiếc hộp; nó nằm ở chất lượng của bí mật, hành vi của toàn bộ hệ thống, tính độc lập của các lớp phòng thủ, sự rõ ràng của giao diện và bằng chứng sẵn có để xác minh mọi tuyên bố quan trọng. Độ phức tạp có thể cần thiết, nhưng nó phải chứng minh giá trị của mình qua từng mối đe dọa được kiểm soát.

Hãy đọc tiếp các hướng dẫn của Oath về [Create your first wallet](https://help.oathwallet.org/articles/create-wallet), [passphrase BIP39](https://oathwallet.org/articles/add-bip39-passphrase-oath-wallet), [mô hình bảo mật tự lưu ký](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model) và [mã khóa ứng dụng cùng các biện pháp kiểm soát quyền riêng tư](https://oathwallet.org/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy).

## Nguồn chính và nguồn kỹ thuật

- 

[Coinkite: Khuyến cáo bảo mật Coldcard](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) — các phiên bản bị ảnh hưởng, phạm vi entropy, bản phát hành sửa lỗi và hướng dẫn di chuyển.

- 

[Coldcard: Trạng thái bảo mật hiện tại](https://coldcard.com/security/status) — các bản phát hành hiện tại, phạm vi xác thực độc lập, giới hạn và tình trạng báo cáo hậu kiểm.

- 

[TRM Labs: Đánh giá on-chain ngày 5 tháng 8](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) — ước tính tổn thất tại một thời điểm xác định và phân tích luồng giao dịch.

- 

[Kraken Security Labs: Công bố về tiêm lỗi Trezor](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) — trích xuất seed bằng truy cập vật lý và biện pháp giảm thiểu bằng passphrase.

- 

[Ledger: Báo cáo sự cố Connect Kit](https://www.ledger.com/blog/security-incident-report) — việc phát hành phần phụ thuộc độc hại và tác động đến hoạt động ký của người dùng.

- 

[Block: Nghiên cứu cửa hậu firmware](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) — rò rỉ bí mật qua chữ ký và các biện pháp giảm thiểu rủi ro chuỗi cung ứng.

- 

[Apple Platform Security: Bảo mật ứng dụng và ký mã](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) — các biện pháp kiểm soát của iOS về phân phối, sandbox và tính toàn vẹn khi chạy.

- 

[Ordekian, Atondo-Siu, Hutchings và Vasek: Nghiên cứu về tấn công bằng bạo lực](https://doi.org/10.4230/LIPIcs.AFT.2024.10) — phân tích an ninh vật lý đã qua bình duyệt.

- 

[Bộ Tư pháp Hoa Kỳ: Các bản án về đột nhập nhà để cướp tiền mã hóa](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) — hoạt động cưỡng ép vật lý và giám sát đã được ghi nhận.

Oath không có quan hệ liên kết với, cũng không nhận được sự chứng thực của Coldcard, Coinkite, Trezor, Kraken, Ledger, Block hay các nhà nghiên cứu được trích dẫn. Tên sản phẩm và công ty thuộc quyền sở hữu của các chủ thể tương ứng. Bài viết này nhằm mục đích giáo dục về bảo mật, không phải lời khuyên tài chính, pháp lý hoặc khẩn cấp dành riêng cho cá nhân. Không bao giờ cung cấp cụm từ khôi phục, khóa riêng, passphrase ví, mã khóa ứng dụng hoặc mật khẩu bản sao lưu cho trang web, nhân viên hỗ trợ, nhà nghiên cứu hay trợ lý AI.
