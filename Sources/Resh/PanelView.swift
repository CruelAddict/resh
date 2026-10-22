import AppKit
import ReshCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var searchFocused: Bool

    private var foreground: Color { model.theme.foreground.color }
    private var accent: Color { model.theme.accent.color }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(accent)
                Text("resh").font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Projects & sessions").font(.system(size: 12)).foregroundStyle(foreground.opacity(0.5))
                Spacer()
                Text(model.theme.name).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.4)).lineLimit(1)
                keycap("esc")
            }
            .padding(.horizontal, 24).padding(.top, 21).padding(.bottom, 17)

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .regular))
                    .foregroundStyle(accent.opacity(0.8))
                TextField("Find a project, folder, or session…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 21, weight: .regular))
                    .focused($searchFocused).accessibilityIdentifier("resh.search")
                    .onChange(of: model.query) { _, _ in model.selection = 0 }
                if model.isLoading || model.isConnecting { ProgressView().controlSize(.small) }
                else if !model.query.isEmpty {
                    Button { model.query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(foreground.opacity(0.4))
                    }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(16)
            .background(foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(foreground.opacity(0.08)))
            .padding(.horizontal, 20)

            HStack(spacing: 5) {
                ForEach([SearchScope.sessions, .all, .directories, .find], id: \.self) { scope in
                    Button { model.changeScope(scope); searchFocused = true } label: {
                        HStack(spacing: 6) {
                            Text(scope.title).font(.system(size: 11, weight: model.scope == scope ? .semibold : .medium))
                            Text(scope.shortcut).font(.system(size: 10)).opacity(0.5)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(model.scope == scope ? accent.opacity(0.14) : .clear, in: Capsule())
                        .foregroundStyle(model.scope == scope ? accent : foreground.opacity(0.5))
                        .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("resh.scope.\(scope.rawValue)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            Rectangle().fill(foreground.opacity(0.08)).frame(height: 1).padding(.horizontal, 20)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if model.results.isEmpty && !model.isLoading {
                            VStack(spacing: 10) {
                                Image(systemName: "folder.badge.questionmark").font(.system(size: 30, weight: .light))
                                Text(model.query.isEmpty ? "No \(model.scope.title.lowercased()) yet" : "No matching projects")
                                    .font(.system(size: 14, weight: .medium))
                                Text("⌃X for recent folders · ⌃F to search your home folder")
                                    .font(.system(size: 11)).opacity(0.6)
                            }.foregroundStyle(foreground.opacity(0.5)).frame(maxWidth: .infinity).padding(.top, 55)
                        }
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, candidate in
                            row(candidate, selected: model.selection == index)
                                .id(candidate.id)
                                .onTapGesture { model.selection = index; model.openSelection() }
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 9)
                }
                .onChange(of: model.selection) { _, index in
                    if model.results.indices.contains(index) { scroll.scrollTo(model.results[index].id) }
                }
            }

            Rectangle().fill(foreground.opacity(0.08)).frame(height: 1)
            HStack(spacing: 7) {
                if model.error != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                Text(model.status).font(.system(size: 11)).lineLimit(3)
                    .foregroundStyle(model.error == nil ? foreground.opacity(0.55) : Color.orange)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                if model.error == nil {
                    Text("\(model.results.count)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(foreground.opacity(0.35))
                    keycap("↑↓"); Text("navigate").font(.system(size: 10)).foregroundStyle(foreground.opacity(0.4))
                    keycap("↵")
                } else {
                    Button("Retry") { model.reload() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                }
            }.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .foregroundStyle(foreground)
        .frame(width: 740, height: 520)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .onAppear { searchFocused = true }
    }

    private func row(_ candidate: Candidate, selected: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: candidate.kind == .session ? "rectangle.stack.fill" : "folder.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(selected ? accent : foreground.opacity(0.45))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title).font(.system(size: 14, weight: selected ? .semibold : .medium)).lineLimit(1)
                Text(candidate.subtitle).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(foreground.opacity(selected ? 0.65 : 0.4)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(candidate.kind == .session ? "SESSION" : "FOLDER")
                .font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1)
                .foregroundStyle(foreground.opacity(0.3))
            Image(systemName: "return").font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent).opacity(selected ? 1 : 0).frame(width: 18)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? model.theme.selection.color.opacity(0.65) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? accent.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func keycap(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(foreground.opacity(0.45)).padding(.horizontal, 5).padding(.vertical, 3)
            .background(foreground.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
    }
}
