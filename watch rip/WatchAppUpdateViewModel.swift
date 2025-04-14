import Foundation
import SwiftUI // Combine 和 ObservableObject 需要 SwiftUI 或 Combine
 
class WatchAppUpdateViewModel: ObservableObject {
    @Published var status: WatchAppUpdateStatus = .checking
} 