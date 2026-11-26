import SwiftUI

/// DBeaver-style calculator shown in the same right-hand slot as the value
/// inspector. It works on ordinary numbers and can take the focused cell's
/// value as a starting point.
struct CalcPanelView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var expressionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    expressionField
                    resultBox
                    actions
                    if !model.calcHistory.isEmpty {
                        Divider()
                        history
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 560)
        .onAppear { expressionFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "function")
                .foregroundColor(.secondary)
            Text(L10n.tr("Калькулятор"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                model.showCalcPanel = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("Закрыть калькулятор"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var expressionField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("Выражение"))
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(L10n.tr("Например: (12,5 + 3) * 2"), text: $model.calcExpression)
                .font(.system(size: 15, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .focused($expressionFocused)
                .onSubmit { model.evaluateCalc() }
            Text(L10n.tr("Поддерживаются + − * / % ^, скобки, sqrt, abs, sin, cos, ln, log, min, max."))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var resultBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("Результат"))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(model.calcResult.isEmpty ? "—" : model.calcResult)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.tr("Вычислить")) { model.evaluateCalc() }
                .keyboardShortcut(.return, modifiers: [.command])
                .help(L10n.tr("Вычислить выражение"))
            Button(L10n.tr("Вставить значение")) { model.insertSelectedValueIntoCalc() }
                .help(L10n.tr("Добавить значение выбранной ячейки в выражение"))
            Spacer()
            Button(L10n.tr("Очистить")) {
                model.calcExpression = ""
                model.calcResult = ""
                expressionFocused = true
            }
            .help(L10n.tr("Очистить выражение и результат"))
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("История"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L10n.tr("Очистить историю")) { model.clearCalcHistory() }
                    .controlSize(.mini)
                    .help(L10n.tr("Удалить историю вычислений"))
            }
            ForEach(Array(model.calcHistory.enumerated()), id: \.offset) { _, line in
                Button {
                    model.calcExpression = line
                    expressionFocused = true
                } label: {
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Подставить это выражение"))
            }
        }
    }
}
