//  twitter-text
//
//  Copyright (c) Paweł Madej 2020 | Twitter: @PawelMadejCK
//  License: MIT (see LICENCE files for details)

import Foundation
import UnicodeURL

public class TwitterText {
    static let kMaxURLLength = 4096
    static let kMaxTCOSlugLength = 40
    static let kMaxTweetLengthLegacy = 140
    static let kTransformedURLLength = 23
    static let kPermillageScaleFactor = 1000

    /// The backend adds http:// for normal links and https to *.twitter.com URLs
    /// (it also rewrites http to https for URLs matching *.twitter.com).
    /// We always add https://. By making the assumption that kURLProtocolLength
    /// is https, the trade off is we'll disallow a http URL that is 4096 characters.
    static let kURLProtocolLength = 8

    public static func entities(inText text: String) -> [Entity] {
        if text.isEmpty {
            return []
        }

        var results: [Entity] = []
        let urls = self.URLs(inText: text)
        results.append(contentsOf: urls)

        let hashtags = self.hashtags(inText: text, withURLEntities: urls)
        results.append(contentsOf: hashtags)

        let symbols = self.symbols(inText: text, withURLEntities: urls)
        results.append(contentsOf: symbols)

        var addingItems: [Entity] = []

        let mentionsAndLists = mentionsOrLists(inText: text)
        for entity in mentionsAndLists {
            let entityRange = entity.range
            var found = false
            for existingEntity in results {
                if NSIntersectionRange(existingEntity.range, entityRange).length > 0 {
                    found = true
                    break
                }
            }
            if !found {
                addingItems.append(entity)
            }
        }

        results.append(contentsOf: addingItems)

        return results
    }

    public static func URLs(inText text: String) -> [Entity] {
        if text.isEmpty {
            return []
        }

        var results: [Entity] = []
        let len = text.utf16.count
        var position = 0
        var allRange = NSMakeRange(0, 0)

        while true {
            position = NSMaxRange(allRange)

            if len <= position {
                break
            }

            guard let urlResult = self.validURLRegexp.firstMatch(in: text, options: [.withoutAnchoringBounds] , range: NSMakeRange(position, len - position)) else {
                break
            }

            allRange = urlResult.range

            if urlResult.numberOfRanges < 9 {
                continue
            }

            let urlRange = urlResult.range(at: ValidURLGroup.url.rawValue)
            let precedingRange = urlResult.range(at: ValidURLGroup.preceding.rawValue)
            let protocolRange = urlResult.range(at: ValidURLGroup.urlProtocol.rawValue)
            let domainRange = urlResult.range(at: ValidURLGroup.domain.rawValue)

            let protocolStr = protocolRange.location != NSNotFound ? text.substring(with: Range(protocolRange, in: text)!) : nil
            if protocolStr == nil || protocolStr?.count == 0 {
                let preceding = precedingRange.location != NSNotFound ? text.substring(with: Range(precedingRange, in: text)!) : nil
                if let set = preceding?.rangeOfCharacter(from: self.invalidURLWithoutProtocolPrecedingCharSet, options: [.backwards, .anchored]) {
                    let suffixRange = NSRange(set, in: preceding!)
                    if suffixRange.location != NSNotFound {
                        continue
                    }
                }
            }

            let r = Range(urlRange, in: text)
            var url = urlRange.location != NSNotFound ? text.substring(with: r!) : nil
            let host = domainRange.location != NSNotFound ? text.substring(with: Range(domainRange, in: text)!) : nil

            let start = urlRange.location
            var end = NSMaxRange(urlRange)

            let tcoResult: NSTextCheckingResult?
            if let url = url {
                tcoResult = self.validTCOURLRegexp.firstMatch(in: url, options: [], range: NSMakeRange(0, url.utf16.count))
            } else {
                tcoResult = nil
            }

            if let tcoResult = tcoResult, tcoResult.numberOfRanges >= 2 {
                let tcoRange = tcoResult.range(at: 0)
                let tcoUrlSlugRange = tcoResult.range(at: 1)

                if tcoRange.location == NSNotFound || tcoUrlSlugRange.location == NSNotFound {
                    continue
                }

                let tcoUrlSlug = text.substring(with: Range(tcoUrlSlugRange, in: text)!)

                if tcoUrlSlug.utf16.count > TwitterText.kMaxTCOSlugLength {
                    continue
                } else {
                    url = url?.substring(with: Range(tcoRange, in: url!)!)
                    end = start + url!.utf16.count
                }
            }

            if isValidHostAndLength(urlLength: url!.utf16.count, urlProtocol: protocolStr, host: host) {
                let entity = Entity(withType: .url, range: NSMakeRange(start, end - start))
                results.append(entity)
                allRange = entity.range
            }
        }

        return results
    }

    public static func hashtags(inText text: String, checkingURLOverlap: Bool) -> [Entity] {
        if text.isEmpty {
            return []
        }

        var urls: [Entity] = []
        if checkingURLOverlap {
            urls = self.URLs(inText: text)
        }

        return self.hashtags(inText: text, withURLEntities: urls)
    }

    static func hashtags(inText text: String, withURLEntities urlEntities: [Entity]) -> [Entity] {
        if text.isEmpty {
            return []
        }

        var results: [Entity] = []
        let len = text.utf16.count
        var position = 0

        while true {
            let matchResult = self.validHashtagRegexp.firstMatch(in: text, options: [.withoutAnchoringBounds], range: NSMakeRange(position, len - position))

            guard let result = matchResult, result.numberOfRanges > 1 else {
                break
            }

            let hashtagRange = result.range(at: 1)
            var matchOk = true

            for urlEntity in urlEntities {
                if NSIntersectionRange(urlEntity.range, hashtagRange).length > 0 {
                    matchOk = false
                    break
                }
            }

            if matchOk {
                let afterStart = NSMaxRange(hashtagRange)
                if afterStart < len {
                    let endMatchRange = self.endHashtagRegexp.rangeOfFirstMatch(in: text, options: [], range: NSMakeRange(afterStart, len - afterStart))
                    if endMatchRange.location != NSNotFound {
                        matchOk = false
                    }
                }

                if matchOk {
                    let entity = Entity(withType: .hashtag, range: hashtagRange)
                    results.append(entity)
                }
            }

            position = NSMaxRange(result.range)
        }

        return results
    }

    public static func symbols(inText text: String, checkingURLOverlap: Bool) -> [Entity] {
        if text.isEmpty {
            return []
        }

        var urls: [Entity] = []
        if checkingURLOverlap {
            urls = self.URLs(inText: text)
        }

        return symbols(inText: text, withURLEntities: urls)
    }

    static func symbols(inText text: String, withURLEntities urlEntities: [Entity]) -> [Entity] {
        if text.isEmpty {
            return []
        }

        var results: [Entity] = []
        let len = text.utf16.count
        var position = 0

        while true {
            let matchResult = self.validSymbolRegexp.firstMatch(in: text, options: .withoutAnchoringBounds, range: NSMakeRange(position, len - position))

            guard let result = matchResult, result.numberOfRanges >= 2 else {
                break
            }

            let symbolRange = result.range(at: 1)
            var matchOk = true

            for urlEntity in urlEntities {
                if NSIntersectionRange(urlEntity.range, symbolRange).length > 0 {
                    matchOk = false
                    break
                }
            }

            if matchOk {
                let entity = Entity(withType: .symbol, range: symbolRange)
                results.append(entity)
            }

            position = NSMaxRange(result.range)
        }

        return results
    }

    public static func mentionedScreenNames(inText text: String) -> [Entity] {

        if text.isEmpty {
            return []
        }

        let mentionsOrLists = self.mentionsOrLists(inText: text)
        var results: [Entity] = []

        for entity in mentionsOrLists {
            if entity.type == .screenName {
                results.append(entity)
            }
        }

        return results
    }

    public static func mentionsOrLists(inText text: String) -> [Entity] {
        if text.isEmpty {
            return []
        }

        var results: [Entity] = []
        let len = text.utf16.count
        var position = 0

        while true {
            let matchResult = self.validMentionOrListRegexp.firstMatch(in: text, options: [.withoutAnchoringBounds], range: NSMakeRange(position, len - position))

            guard let result = matchResult, result.numberOfRanges >= 5 else {
                break
            }

            let allRange = result.range
            var end = NSMaxRange(allRange)

            let endMentionRange = self.endMentionRegexp.rangeOfFirstMatch(in: text, options: [], range: NSMakeRange(end, len - end))
            if endMentionRange.location == NSNotFound {
                let atSignRange = result.range(at: 2)
                let screenNameRange = result.range(at: 3)
                let listNameRange = result.range(at: 4)

                if listNameRange.location == NSNotFound {
                    let entity = Entity(withType: .screenName, range: NSMakeRange(atSignRange.location, NSMaxRange(screenNameRange) - atSignRange.location))
                    results.append(entity)
                } else {
                    let entity = Entity(withType: .listname, range: NSMakeRange(atSignRange.location, NSMaxRange(listNameRange) - atSignRange.location))
                    results.append(entity)
                }
            } else {
                end += 1
            }

            position = end
        }

        return results
    }

    public static func repliedScreenName(inText text: String) -> Entity? {
        if text.isEmpty {
            return nil
        }

        let len = text.utf16.count
        let matchResult = self.validReplyRegexp.firstMatch(in: text, options: [.withoutAnchoringBounds, .anchored], range: NSMakeRange(0, len))

        guard let result =  matchResult, result.numberOfRanges >= 2 else {
            return nil
        }

        let replyRange = result.range(at: 1)
        let replyEnd = NSMaxRange(replyRange)
        let endMentionRange = self.endMentionRegexp.rangeOfFirstMatch(in: text, options: [], range: NSMakeRange(replyEnd, len - replyEnd))

        if endMentionRange.location != NSNotFound {
            return nil
        }

        return Entity(withType: .screenName, range: replyRange)
    }

    public static func validHashtagBoundaryCharacterSet() -> CharacterSet {
        var set: CharacterSet = .letters
        set.formUnion(.decimalDigits)
        set.formUnion(CharacterSet(charactersIn: Regexp.TWHashtagSpecialChars + "&"))

        return set.inverted
    }

    public static func tweetLength(text: String) -> Int {
        return self.tweetLength(text: text, transformedURLLength: kTransformedURLLength)
    }

    public static func tweetLength(text: String, transformedURLLength: Int) -> Int {
        // Use Unicode Normalization Form Canonical Composition to calculate tweet text length
        let text = text.precomposedStringWithCanonicalMapping

        if text.isEmpty {
            return 0
        }

        // Remove URLs from text and add t.co length
        var string = text
        var urlLengthOffset = 0
        let urlEntities = URLs(inText: text)

        for urlEntity in urlEntities.reversed() {
            let entity = urlEntity
            let urlRange = entity.range
            urlLengthOffset += transformedURLLength

            let mutableString = NSMutableString(string: string)
            mutableString.deleteCharacters(in: urlRange)
            string = String(mutableString)
        }

        let len = string.count
        var charCount = len + urlLengthOffset

        if len > 0 {
            var buffer: [UniChar] = Array.init(repeating: UniChar(), count: len)

            let mutableString = NSMutableString(string: string)
            mutableString.getCharacters(&buffer, range: NSMakeRange(0, len))

            for index in 0..<len {
                let c = buffer[index]
                if CFStringIsSurrogateHighCharacter(c) {
                    if index + 1 < len {
                        let d = buffer[index + 1]
                        if CFStringIsSurrogateHighCharacter(d) {
                            charCount -= 1
                        }
                    }
                }
            }
        }

        return charCount
    }

    public static func remainingCharacterCount(text: String) -> Int {
        return self.remainingCharacterCount(text: text, transformedURLLength: kTransformedURLLength)
    }

    public static func remainingCharacterCount(text: String, transformedURLLength: Int) -> Int {
        return kMaxTweetLengthLegacy - self.tweetLength(text: text, transformedURLLength: transformedURLLength)
    }

    // MARK: - Private Methods

    internal static let invalidCharacterRegexp = try! NSRegularExpression(pattern: Regexp.TWUInvalidCharactersPattern, options: .caseInsensitive)

    private static let validGTLDRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidGTLD, options: .caseInsensitive)

    private static let validURLRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidURLPatternString, options: .caseInsensitive)

    private static let validDomainRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidDomain, options: .caseInsensitive)

    private static let validTCOURLRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidTCOURL, options: .caseInsensitive)

    private static let validHashtagRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidHashtag, options: .caseInsensitive)

    private static let endHashtagRegexp = try! NSRegularExpression(pattern: Regexp.TWUEndHashTagMatch, options: .caseInsensitive)

    private static let validSymbolRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidSymbol, options: .caseInsensitive)

    private static let validMentionOrListRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidMentionOrList, options: .caseInsensitive)

    private static let validReplyRegexp = try! NSRegularExpression(pattern: Regexp.TWUValidReply, options: .caseInsensitive)

    private static let endMentionRegexp = try! NSRegularExpression(pattern: Regexp.TWUEndMentionMatch, options: .caseInsensitive)

    private static let validDomainSucceedingCharRegexp = try! NSRegularExpression(pattern: Regexp.TWUEndMentionMatch, options: .caseInsensitive)

    private static let invalidURLWithoutProtocolPrecedingCharSet: CharacterSet = {
        CharacterSet.init(charactersIn: "-_./")
    }()

    private static func isValidHostAndLength(urlLength: Int, urlProtocol: String?, host: String?) -> Bool {
        guard var host = host else { return false }
        var urlLength = urlLength
        var hostUrl: URL?
        do {
           hostUrl  = try URL(unicodeUrlString: host)
        }
        catch  let error as UnicodeURLConvertError {
            if error.error == .invalidDNSLength {
                return false
            }
            else {
                hostUrl = URL(string: host)
            }
        }
        catch { }

        if hostUrl == nil {
            hostUrl = URL.init(string: host)
        }

        guard let url = hostUrl else { return false }

        // TODO: Make sure this is correct
//        NSURL *url = [NSURL URLWithUnicodeString:host error:&error];
//        if (error) {
//            if (error.code == IFUnicodeURLConvertErrorInvalidDNSLength) {
//                // If the error is specifically IFUnicodeURLConvertErrorInvalidDNSLength,
//                // just return a false result. NSURL will happily create a URL for a host
//                // with labels > 63 characters (radar 35802213).
//                return NO;
//            } else {
//                // Attempt to create a NSURL object. We may have received an error from
//                // URLWithUnicodeString above because the input is not valid for punycode
//                // conversion (example: non-LDH characters are invalid and will trigger
//                // an error with code == IFUnicodeURLConvertErrorSTD3NonLDH but may be
//                // allowed normally per RFC 1035.
//                url = [NSURL URLWithString:host];
//            }
//        }

        let originalHostLength = host.count

        host = url.absoluteString
        let updatedHostLength = host.utf16.count
        if updatedHostLength == 0 {
            return false
        } else if updatedHostLength > originalHostLength {
            urlLength += (updatedHostLength - originalHostLength)
        }

        // Because the backend always adds https:// if we're missing a protocol, add this length
        // back in when checking vs. our maximum allowed length of a URL, if necessary.
        var urlLengthWithProtocol = urlLength
        if urlProtocol == nil {
            urlLengthWithProtocol += TwitterText.kURLProtocolLength
        }
        return urlLengthWithProtocol <= kMaxURLLength

    }
}
