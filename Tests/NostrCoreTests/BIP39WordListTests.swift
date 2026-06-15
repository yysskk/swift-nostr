import Foundation
import NostrCore
import Testing

@Suite("BIP-39 WordList Tests")
struct BIP39WordListTests {

    @Test("BIP-39 wordlist has 2048 words")
    func wordlistSize() {
        #expect(BIP39WordList.english.count == 2048)
    }

    @Test("BIP-39 wordlist starts with abandon")
    func wordlistFirstWord() {
        #expect(BIP39WordList.english[0] == "abandon")
    }

    @Test("BIP-39 wordlist ends with zoo")
    func wordlistLastWord() {
        #expect(BIP39WordList.english[2047] == "zoo")
    }

    @Test("BIP-39 wordlist contains common words")
    func wordlistContainsCommonWords() {
        let commonWords = ["ability", "banana", "carbon", "dog", "energy", "fish", "garden", "home"]
        for word in commonWords {
            #expect(BIP39WordList.english.contains(word))
        }
    }

    @Test("BIP-39 wordlist is sorted alphabetically")
    func wordlistIsSorted() {
        let sorted = BIP39WordList.english.sorted()
        #expect(BIP39WordList.english == sorted)
    }

    @Test("BIP-39 wordlist has no duplicates")
    func wordlistNoDuplicates() {
        let uniqueWords = Set(BIP39WordList.english)
        #expect(uniqueWords.count == BIP39WordList.english.count)
    }
}
