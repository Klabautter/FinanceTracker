import SwiftUI

extension TagColorToken {
    var color: Color {
        switch self {
        case .blue: CategoryColorToken.blue.color
        case .green: CategoryColorToken.green.color
        case .orange: CategoryColorToken.orange.color
        case .purple: CategoryColorToken.purple.color
        case .red: CategoryColorToken.red.color
        case .teal: CategoryColorToken.teal.color
        case .yellow: CategoryColorToken.yellow.color
        case .indigo: CategoryColorToken.indigo.color
        case .gray: CategoryColorToken.gray.color
        }
    }
}
