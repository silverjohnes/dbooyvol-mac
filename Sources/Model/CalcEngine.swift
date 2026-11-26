import Foundation

/// Small arithmetic evaluator behind the Calc panel. It accepts the usual
/// operators, parentheses, a few functions and `,` as a decimal separator, so
/// values copied from a Russian-locale grid can be pasted directly.
enum CalcEngine {
    enum EvalError: Error {
        case message(String)
    }

    static func isNumeric(_ text: String) -> Bool {
        Double(text.replacingOccurrences(of: ",", with: ".")) != nil
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : "∞" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 12
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func format(_ text: String) -> String {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return text }
        return format(value)
    }

    struct CalcError: Error {
        let message: String
    }

    static func evaluate(_ expression: String) -> Result<Double, CalcError> {
        var parser = Parser(expression)
        do {
            let value = try parser.parse()
            guard value.isFinite else {
                return .failure(CalcError(message: L10n.tr("Результат не является числом")))
            }
            return .success(value)
        } catch let EvalError.message(message) {
            return .failure(CalcError(message: message))
        } catch {
            return .failure(CalcError(message: L10n.tr("Не удалось вычислить выражение")))
        }
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) {
            characters = Array(text)
        }

        mutating func parse() throws -> Double {
            let value = try expression()
            skipSpaces()
            guard index >= characters.count else {
                throw EvalError.message(L10n.tr("Лишние символы в выражении"))
            }
            return value
        }

        private mutating func expression() throws -> Double {
            var value = try term()
            while true {
                skipSpaces()
                if consume("+") {
                    value += try term()
                } else if consume("-") {
                    value -= try term()
                } else {
                    return value
                }
            }
        }

        private mutating func term() throws -> Double {
            var value = try power()
            while true {
                skipSpaces()
                if consume("*") {
                    value *= try power()
                } else if consume("/") {
                    let divisor = try power()
                    guard divisor != 0 else {
                        throw EvalError.message(L10n.tr("Деление на ноль"))
                    }
                    value /= divisor
                } else if consume("%") {
                    let divisor = try power()
                    guard divisor != 0 else {
                        throw EvalError.message(L10n.tr("Деление на ноль"))
                    }
                    value = value.truncatingRemainder(dividingBy: divisor)
                } else {
                    return value
                }
            }
        }

        private mutating func power() throws -> Double {
            let base = try unary()
            skipSpaces()
            if consume("^") {
                return pow(base, try power())
            }
            return base
        }

        private mutating func unary() throws -> Double {
            skipSpaces()
            if consume("+") { return try unary() }
            if consume("-") { return -(try unary()) }
            return try primary()
        }

        private mutating func primary() throws -> Double {
            skipSpaces()
            if consume("(") {
                let value = try expression()
                skipSpaces()
                guard consume(")") else {
                    throw EvalError.message(L10n.tr("Не закрыта скобка"))
                }
                return value
            }
            if let number = number() { return number }
            if let name = identifier() {
                let lower = name.lowercased()
                switch lower {
                case "pi", "π": return Double.pi
                case "e": return M_E
                default: break
                }
                skipSpaces()
                guard consume("(") else {
                    throw EvalError.message(L10n.fmt("Неизвестное имя: %@", name))
                }
                var arguments: [Double] = []
                skipSpaces()
                if !consume(")") {
                    while true {
                        arguments.append(try expression())
                        skipSpaces()
                        if consume(")") { break }
                        guard consume(",") else {
                            throw EvalError.message(L10n.tr("Не закрыта скобка"))
                        }
                    }
                }
                return try apply(function: lower, arguments: arguments)
            }
            throw EvalError.message(L10n.tr("Ожидалось число"))
        }

        private func apply(function: String, arguments: [Double]) throws -> Double {
            switch function {
            case "sqrt":
                guard arguments.count == 1 else { throw arity(function) }
                return sqrt(arguments[0])
            case "abs":
                guard arguments.count == 1 else { throw arity(function) }
                return abs(arguments[0])
            case "sin":
                guard arguments.count == 1 else { throw arity(function) }
                return sin(arguments[0])
            case "cos":
                guard arguments.count == 1 else { throw arity(function) }
                return cos(arguments[0])
            case "tan":
                guard arguments.count == 1 else { throw arity(function) }
                return tan(arguments[0])
            case "ln":
                guard arguments.count == 1 else { throw arity(function) }
                return log(arguments[0])
            case "log":
                guard arguments.count == 1 else { throw arity(function) }
                return log10(arguments[0])
            case "exp":
                guard arguments.count == 1 else { throw arity(function) }
                return exp(arguments[0])
            case "round":
                guard arguments.count == 1 else { throw arity(function) }
                return arguments[0].rounded()
            case "floor":
                guard arguments.count == 1 else { throw arity(function) }
                return floor(arguments[0])
            case "ceil":
                guard arguments.count == 1 else { throw arity(function) }
                return ceil(arguments[0])
            case "min":
                guard !arguments.isEmpty else { throw arity(function) }
                return arguments.min() ?? 0
            case "max":
                guard !arguments.isEmpty else { throw arity(function) }
                return arguments.max() ?? 0
            default:
                throw EvalError.message(L10n.fmt("Неизвестная функция: %@", function))
            }
        }

        private func arity(_ function: String) -> EvalError {
            EvalError.message(L10n.fmt("Неверное число аргументов: %@", function))
        }

        private mutating func number() -> Double? {
            skipSpaces()
            let start = index
            var text = ""
            var hasSeparator = false
            while index < characters.count {
                let character = characters[index]
                if character.isNumber {
                    text.append(character)
                    index += 1
                } else if character == "." || character == "," {
                    guard !hasSeparator else { break }
                    // A comma followed by a space is an argument separator
                    // (`min(1, 2)`); without a space it is a decimal comma
                    // (`12,5`), which is what a Russian-locale grid produces.
                    if character == ",",
                       index + 1 < characters.count,
                       characters[index + 1].isWhitespace {
                        break
                    }
                    hasSeparator = true
                    text.append(".")
                    index += 1
                } else if character == "e" || character == "E" {
                    // Scientific notation only when followed by a digit or sign.
                    var look = index + 1
                    if look < characters.count,
                       characters[look] == "+" || characters[look] == "-" {
                        look += 1
                    }
                    guard look < characters.count, characters[look].isNumber else { break }
                    text.append(character)
                    index += 1
                    if index < characters.count,
                       characters[index] == "+" || characters[index] == "-" {
                        text.append(characters[index])
                        index += 1
                    }
                } else {
                    break
                }
            }
            guard index > start, let value = Double(text) else {
                index = start
                return nil
            }
            return value
        }

        private mutating func identifier() -> String? {
            skipSpaces()
            let start = index
            while index < characters.count {
                let character = characters[index]
                if character.isLetter || character == "_" {
                    index += 1
                } else {
                    break
                }
            }
            guard index > start else { return nil }
            return String(characters[start..<index])
        }

        private mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
        }

        private mutating func consume(_ text: String) -> Bool {
            skipSpaces()
            guard let character = text.first, index < characters.count,
                  characters[index] == character else { return false }
            index += 1
            return true
        }
    }
}
