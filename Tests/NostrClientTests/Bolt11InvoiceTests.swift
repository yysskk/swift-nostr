import Crypto
import Foundation
import Testing

@testable import NostrClient

@Suite("BOLT-11 Invoice Tests")
struct Bolt11InvoiceTests {
    // The canonical BOLT-11 test vectors share this payment hash and creation timestamp.
    private let paymentHashHex = "0001020304050607080900010203040506070809000102030405060708090102"
    private let timestamp = Date(timeIntervalSince1970: 1_496_314_658)

    // The description committed to by the `h` field in the 20m vectors.
    private let descriptionHashSource =
        "One piece of chocolate cake, one icecream cone, one pickle, one slice of swiss cheese, "
        + "one slice of salami, one lollypop, one piece of cherry pie, one sausage, one cupcake, "
        + "and one slice of watermelon"

    @Test("decodes the amountless donation invoice")
    func amountlessDonation() throws {
        let invoice = try #require(
            Bolt11Invoice(
                "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql"
            ))

        #expect(invoice.amountMillisats == nil)
        #expect(invoice.timestamp == timestamp)
        #expect(invoice.description == "Please consider supporting this project")
        #expect(invoice.paymentHash?.hexEncodedString() == paymentHashHex)
        #expect(invoice.descriptionHash == nil)
    }

    @Test("decodes the 2500u coffee invoice with amount and expiry")
    func coffeeInvoice() throws {
        let invoice = try #require(
            Bolt11Invoice(
                "lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf39tuven09sam30g4vgpfna3rh"
            ))

        #expect(invoice.amountMillisats == 250_000_000)
        #expect(invoice.description == "1 cup coffee")
        #expect(invoice.expirySeconds == 60)
        #expect(invoice.paymentHash?.hexEncodedString() == paymentHashHex)
    }

    @Test("decodes the 20m invoice with a description hash")
    func descriptionHashInvoice() throws {
        let invoice = try #require(
            Bolt11Invoice(
                "lnbc20m1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqhp58yjmdan79s6qqdhdzgynm4zwqd5d7xmw5fk98klysy043l2ahrqs9qrsgq7ea976txfraylvgzuxs8kgcw23ezlrszfnh8r6qtfpr6cxga50aj6txm9rxrydzd06dfeawfk6swupvz4erwnyutnjq7x39ymw6j38gp7ynn44"
            ))

        let expectedHash = Data(SHA256.hash(data: Data(descriptionHashSource.utf8)))
        #expect(invoice.amountMillisats == 2_000_000_000)
        #expect(invoice.descriptionHash == expectedHash)
        #expect(invoice.description == nil)
    }

    @Test("decodes the pico-multiplier amount (divides by 10)")
    func picoMultiplier() throws {
        // 9678785340p ÷ 10 = 967878534 msats.
        let invoice = try #require(
            Bolt11Invoice(
                "lnbc9678785340p1pwmna7lpp5gc3xfm08u9qy06djf8dfflhugl6p7lgza6dsjxq454gxhj9t7a0sd8dgfkx7cmtwd68yetpd5s9xar0wfjn5gpc8qhrsdfq24f5ggrxdaezqsnvda3kkum5wfjkzmfqf3jkgem9wgsyuctwdus9xgrcyqcjcgpzgfskx6eqf9hzqnteypzxz7fzypfhg6trddjhygrcyqezcgpzfysywmm5ypxxjemgw3hxjmn8yptk7untd9hxwg3q2d6xjcmtv4ezq7pqxgsxzmnyyqcjqmt0wfjjq6t5v4khxsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygsxqyjw5qcqp2rzjq0gxwkzc8w6323m55m4jyxcjwmy7stt9hwkwe2qxmy8zpsgg7jcuwz87fcqqeuqqqyqqqqlgqqqqn3qq9q9qrsgqrvgkpnmps664wgkp43l22qsgdw4ve24aca4nymnxddlnp8vh9v2sdxlu5ywdxefsfvm0fq3sesf08uf6q9a2ke0hc9j6z6wlxg5z5kqpu2v9wz"
            ))
        #expect(invoice.amountMillisats == 967_878_534)
    }

    @Test("decodes a testnet (lntb) invoice — currency prefix is not hardcoded")
    func testnetInvoice() throws {
        let invoice = try #require(
            Bolt11Invoice(
                "lntb20m1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygshp58yjmdan79s6qqdhdzgynm4zwqd5d7xmw5fk98klysy043l2ahrqspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqfpp3x9et2e20v6pu37c5d9vax37wxq72un989qrsgqdj545axuxtnfemtpwkc45hx9d2ft7x04mt8q7y6t0k2dge9e7h8kpy9p34ytyslj3yu569aalz2xdk8xkd7ltxqld94u8h2esmsmacgpghe9k8"
            ))

        #expect(invoice.amountMillisats == 2_000_000_000)
        let expectedHash = Data(SHA256.hash(data: Data(descriptionHashSource.utf8)))
        #expect(invoice.descriptionHash == expectedHash)
    }

    @Test("an uppercase invoice decodes the same as lowercase")
    func uppercaseInvoice() throws {
        let lower =
            "lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf39tuven09sam30g4vgpfna3rh"
        let invoice = try #require(Bolt11Invoice(lower.uppercased()))
        #expect(invoice.amountMillisats == 250_000_000)
        #expect(invoice.description == "1 cup coffee")
    }

    @Test("an invalid invoice returns nil")
    func invalidInvoices() {
        #expect(Bolt11Invoice("not a bolt11 invoice") == nil)  // not bech32
        #expect(Bolt11Invoice("lnbc2500u1deadbeef") == nil)  // bad checksum
        #expect(Bolt11Invoice("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4") == nil)  // not an "ln" invoice
    }
}
