import Foundation

struct SendURIComponents {
    struct Parameter {
        let name: String
        let value: String
    }

    let path: String
    let parameters: [Parameter]

    init(body: String) throws {
        guard
            !body.isEmpty,
            !body.contains("#")
        else {
            throw body.isEmpty
                ? SendPaymentRequestError.missingRecipient
                : SendPaymentRequestError.unsupportedFormat
        }

        let pieces = body.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            let decodedPath = String(pieces[0]).removingPercentEncoding
        else {
            throw SendPaymentRequestError.unsupportedFormat
        }
        path = decodedPath

        guard pieces.count == 2, !pieces[1].isEmpty else {
            parameters = []
            return
        }

        parameters = try pieces[1].split(
            separator: "&",
            omittingEmptySubsequences: false
        ).map { rawParameter in
            guard !rawParameter.isEmpty else {
                throw SendPaymentRequestError.unsupportedFormat
            }
            let pair = rawParameter.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard
                let decodedName = String(pair[0])
                    .removingPercentEncoding,
                !decodedName.isEmpty,
                let decodedValue = (
                    pair.count == 2 ? String(pair[1]) : ""
                ).removingPercentEncoding
            else {
                throw SendPaymentRequestError.unsupportedFormat
            }
            return Parameter(
                name: decodedName,
                value: decodedValue
            )
        }
    }

    func firstValue(
        named name: String,
        includingRequiredVariant: Bool = false,
        caseInsensitive: Bool = false
    ) -> String? {
        values(
            named: name,
            includingRequiredVariant: includingRequiredVariant,
            caseInsensitive: caseInsensitive
        ).first
    }

    func values(
        named name: String,
        includingRequiredVariant: Bool = false,
        caseInsensitive: Bool = false
    ) -> [String] {
        parameters.compactMap { parameter in
            let isDirectMatch = matches(
                parameter.name,
                name,
                caseInsensitive: caseInsensitive
            )
            let isRequiredVariant = includingRequiredVariant
                && matches(
                    parameter.name,
                    "req-\(name)",
                    caseInsensitive: caseInsensitive
                )
            return isDirectMatch || isRequiredVariant
                ? parameter.value
                : nil
        }
    }

    func rejectDuplicateParameters(
        named names: Set<String>,
        includingRequiredVariants: Bool = false,
        caseInsensitive: Bool = false
    ) throws {
        for name in names where values(
            named: name,
            includingRequiredVariant: includingRequiredVariants,
            caseInsensitive: caseInsensitive
        ).count > 1 {
            throw SendPaymentRequestError.duplicateParameter
        }
    }

    func rejectUnknownRequiredParameters(
        allowedNames: Set<String>
    ) throws {
        let normalizedAllowed = Set(
            allowedNames.map { $0.lowercased() }
        )
        for parameter in parameters {
            let normalizedName = parameter.name.lowercased()
            guard normalizedName.hasPrefix("req-") else { continue }
            let baseName = String(normalizedName.dropFirst(4))
            guard normalizedAllowed.contains(baseName) else {
                throw SendPaymentRequestError
                    .unsupportedRequiredParameter
            }
        }
    }

    func rejectParameters(
        except allowedNames: Set<String>,
        allowsRequiredPrefix: Bool = false,
        caseInsensitive: Bool = false
    ) throws {
        for parameter in parameters {
            let comparableName = caseInsensitive
                ? parameter.name.lowercased()
                : parameter.name
            if allowedNames.contains(comparableName) {
                continue
            }
            if allowsRequiredPrefix,
               comparableName.hasPrefix("req-"),
               allowedNames.contains(
                   String(comparableName.dropFirst(4))
               ) {
                continue
            }
            throw SendPaymentRequestError.unsupportedParameter
        }
    }

    private func matches(
        _ lhs: String,
        _ rhs: String,
        caseInsensitive: Bool
    ) -> Bool {
        caseInsensitive
            ? lhs.caseInsensitiveCompare(rhs) == .orderedSame
            : lhs == rhs
    }
}
