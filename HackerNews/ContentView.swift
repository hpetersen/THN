import SwiftUI

struct ContentView: View {
    @State private var frontPage = FrontPageModel()
    @State private var path = NavigationPath()
    @State private var session = HNSession.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Launch arguments for device screenshots (debug builds only): `-screen story|browser|account|search|user:<name>`.
    #if DEBUG
    private let launchScreen = UserDefaults.standard.string(forKey: "screen")
    #else
    private let launchScreen: String? = nil
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            FrontPageView(model: frontPage)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Story.self) { story in
                    StoryView(story: story, openBrowserOnAppear: launchScreen == "browser" && story.id == frontPage.autoStory)
                }
                .navigationDestination(for: UserRoute.self) { route in
                    ProfileView(username: route.name)
                }
                .navigationDestination(for: ItemRoute.self) { route in
                    ItemLoaderView(id: route.id)
                }
                .navigationDestination(for: AccountRoute.self) { _ in
                    AccountView()
                }
                .navigationDestination(for: SearchRoute.self) { _ in
                    SearchView()
                }
        }
        .environment(session)
        .tint(Theme.accent)
        .preferredColorScheme(.light)
        .sheet(isPresented: $session.showSignIn) {
            SignInSheet().environment(session)
        }
        .extrasPresentations()
        .task {
            // Let the front page settle before anything is presented over it.
            try? await Task.sleep(for: .seconds(launchScreen == nil ? 1.5 : 0))
            await Extras.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Extras.didBecomeActive() }
            if phase == .background { Extras.didEnterBackground() }
        }
        .onAppear {
            #if DEBUG
            if let feed = UserDefaults.standard.string(forKey: "feed").flatMap(Feed.init(rawValue:)) {
                frontPage.feed = feed
            }
            #endif
            switch launchScreen {
            case "account": path.append(AccountRoute())
            case "search": path.append(SearchRoute())
            case let s? where s.hasPrefix("user:"): path.append(UserRoute(name: String(s.dropFirst(5))))
            default: break
            }
        }
        .onChange(of: frontPage.stories) { _, stories in
            guard launchScreen == "story" || launchScreen == "browser", frontPage.autoStory == nil,
                  let story = stories.first(where: { $0.link != nil && $0.commentCount > 5 }) ?? stories.first
            else { return }
            frontPage.autoStory = story.id
            path.append(story)
        }
    }
}

#Preview {
    ContentView()
}
