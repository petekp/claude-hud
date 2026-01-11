import SwiftUI

struct TodosSection: View {
    let todos: [Todo]

    var body: some View {
        if todos.isEmpty {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    DetailSectionLabel(title: "TODOS")
                    Text("No todos recorded")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            )
        }

        let completed = todos.filter { $0.isCompleted }.count
        let inProgress = todos.filter { $0.isInProgress }.count

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                DetailSectionLabel(title: "TODOS")

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green.opacity(0.7))
                        Text("\(completed)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.7))
                        Text("\(inProgress)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text("\(todos.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(todos.prefix(5)) { todo in
                        TodoItem(todo: todo)
                    }

                    if todos.count > 5 {
                        Text("+\(todos.count - 5) more")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
        )
    }
}

struct TodoItem: View {
    let todo: Todo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if todo.isCompleted {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green.opacity(0.6))
            } else if todo.isInProgress {
                Image(systemName: "play.square.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.6))
            } else {
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .offset(y: 2)
            }

            Text(todo.content)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(todo.isCompleted ? 0.4 : 0.7))
                .strikethrough(todo.isCompleted)
                .lineLimit(2)

            Spacer()
        }
    }
}
