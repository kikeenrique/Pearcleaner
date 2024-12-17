//
//  DeepLink.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/9/23.
//

import Foundation
import SwiftUI
import AlinFoundation

class DeeplinkManager {
    @Binding var showPopover: Bool
    private var urlQueue: [URL] = []
    private var isProcessing = false
    let updater: Updater
    let fsm: FolderSettingsManager
    @AppStorage("settings.general.mini") private var mini: Bool = false
    @AppStorage("settings.general.oneshot") private var oneShotMode: Bool = false
    @AppStorage("settings.general.selectedTab") private var selectedTab: CurrentTabView = .general
    @State private var windowController = WindowManager()

    init(showPopover: Binding<Bool>, updater: Updater, fsm: FolderSettingsManager) {
        _showPopover = showPopover
        self.updater = updater
        self.fsm = fsm
    }

    struct DeepLinkActions {
        static let openPearcleaner = "openPearcleaner"
        static let openSettings = "openSettings"
        static let openPermissions = "openPermissions"
        static let uninstallApp = "uninstallApp"
        static let checkOrphanedFiles = "checkOrphanedFiles"
        static let checkDevEnv = "checkDevEnv"
        static let checkUpdates = "checkUpdates"
//        static let addFolder = "addFolder"
//        static let removeFolder = "removeFolder"
//        static let addExcludeFolder = "addExcludeFolder"
//        static let removeExcludeFolder = "removeExcludeFolder"
        static let refreshAppsList = "refreshAppsList"
        static let resetSettings = "resetSettings"

        static let allActions = [
            openPearcleaner,
            openSettings,
            openPermissions,
            uninstallApp,
            checkOrphanedFiles,
            checkDevEnv,
            checkUpdates,
//            addFolder,
//            removeFolder,
//            addExcludeFolder,
//            removeExcludeFolder,
            refreshAppsList,
            resetSettings
        ]
    }

    func manage(url: URL, appState: AppState, locations: Locations) {
        // Set externalMode to true
        updateOnMain {
            appState.externalMode = true
        }

        guard let scheme = url.scheme, scheme == "pear" else {
            handleAsPathOrDropped(url: url, appState: appState, locations: locations)
            return
        }

        if let host = url.host, DeepLinkActions.allActions.contains(host) {
            switch host {
            case DeepLinkActions.uninstallApp:
                handleAsPathOrDropped(url: url, appState: appState, locations: locations)
            default:
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                   let queryItems = components.queryItems {
                    handleAppFunctions(action: host, queryItems: queryItems, appState: appState, locations: locations)
                } else {
                    handleAppFunctions(action: host, queryItems: [], appState: appState, locations: locations)
                }
            }
        } else {
            // Host is nil or not in actions, treat as dropped/path scenario
            handleAsPathOrDropped(url: url, appState: appState, locations: locations)
        }
    }

    private func handleAsPathOrDropped(url: URL, appState: AppState, locations: Locations) {
        urlQueue.append(url)
        processQueue(appState: appState, locations: locations)
        if appState.appInfo.isEmpty {
            loadNextAppInfo(appState: appState, locations: locations)
        }
    }

    private func processQueue(appState: AppState, locations: Locations) {
        guard !isProcessing, let nextURL = urlQueue.first else { return }

        isProcessing = true

        // Process the next URL in the queue
        if nextURL.pathExtension == "app" {
            handleDroppedApps(url: nextURL, appState: appState, locations: locations)
        } else if nextURL.scheme == "pear" {
            handleDeepLinkedApps(url: nextURL, appState: appState, locations: locations)
        }

        // Remove processed URL and set up for the next one
        urlQueue.removeFirst()
        isProcessing = false

        // Process the next URL if there are any left in the queue
        if !urlQueue.isEmpty {
            processQueue(appState: appState, locations: locations)
        }
    }

    private func handleDroppedApps(url: URL, appState: AppState, locations: Locations) {
        // Ensure the dropped app path is added only if it's not already in externalPaths
        if !appState.externalPaths.contains(url) {
            appState.externalPaths.append(url)
        }

        // If no app is currently loaded, load the first app in the array
        if appState.appInfo.isEmpty {
            loadNextAppInfo(appState: appState, locations: locations)
        }
    }

    func handleDeepLinkedApps(url: URL, appState: AppState, locations: Locations) {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let queryItems = components.queryItems {

            // Check for "path" query item first
            if let path = queryItems.first(where: { $0.name == "path" })?.value {
                let pathURL = URL(fileURLWithPath: path)

                // Add path only if it's not already in externalPaths
                if !appState.externalPaths.contains(pathURL) {
                    appState.externalPaths.append(pathURL)
                }

                // Load the first app in externalPaths if no app is currently loaded
                if appState.appInfo.isEmpty {
                    loadNextAppInfo(appState: appState, locations: locations)
                }
            }
            // If "path" is not available, check for "name" query item
            else if let name = queryItems.first(where: { $0.name == "name" })?.value?.lowercased() {
                reloadAppsList(appState: appState, fsm: fsm) {
                    let matchType = queryItems.first(where: { $0.name == "matchType" })?.value?.lowercased() ?? "exact"

                    if let matchedApp = appState.sortedApps.first(where: { appInfo in
                        let appNameLowercased = appInfo.appName.lowercased()
                        switch matchType {
                        case "contains":
                            return appNameLowercased.contains(name)
                        case "exact":
                            return appNameLowercased == name
                        default:
                            return false
                        }
                    }) {
                        let pathURL = matchedApp.path

                        // Add path only if it's not already in externalPaths
                        if !appState.externalPaths.contains(pathURL) {
                            appState.externalPaths.append(pathURL)
                        }

                        // Load the first app in externalPaths if no app is currently loaded
                        if appState.appInfo.isEmpty {
                            self.loadNextAppInfo(appState: appState, locations: locations)
                        }
                    } else {
                        printOS("No app found matching the name '\(name)' with matchType: \(matchType)")
                    }
                }

            } else {
                printOS("No valid query items for 'path' or 'name' found in the URL.")
            }
        } else {
            printOS("URL does not match the expected scheme pear://")
        }
    }


    private func loadNextAppInfo(appState: AppState, locations: Locations) {
        guard let nextPath = appState.externalPaths.first else { return }

        // Fetch app info
        let appInfo = AppInfoFetcher.getAppInfo(atPath: nextPath)

        // Pass the appInfo and trigger showAppInFiles to handle display and animations
        showAppInFiles(appInfo: appInfo!, appState: appState, locations: locations, showPopover: $showPopover)
    }

    private func handleAppFunctions(action: String, queryItems: [URLQueryItem], appState: AppState, locations: Locations) {

        switch action {
        case DeepLinkActions.openPearcleaner:
            break
        case DeepLinkActions.openSettings:
            openAppSettings()
            if let page = queryItems.first(where: { $0.name == "name" })?.value {
                let search = page.lowercased()
                let allPages = CurrentTabView.allCases
                if let matchedPage = allPages.first(where: { $0.title.lowercased().contains(search) }) {
                    updateOnMain() {
                        self.selectedTab = matchedPage
                    }
                }
            }
            break
        case DeepLinkActions.openPermissions:
            windowController.open(with: PermissionsListView().ignoresSafeArea(), width: 300, height: 250, material: .hudWindow)
            break
        case DeepLinkActions.checkOrphanedFiles:
            appState.currentPage = .orphans
            break
        case DeepLinkActions.checkDevEnv:
            if let envName = queryItems.first(where: { $0.name == "name" })?.value {
                let search = envName.lowercased()
                let allEnvs = PathLibrary.getPaths()
                if let matchedEnv = allEnvs.first(where: { $0.name.lowercased().contains(search) }) {
                    updateOnMain() {
                        appState.selectedEnvironment = matchedEnv
                    }
                }
            }
            appState.currentPage = .development
            break
        case DeepLinkActions.checkUpdates:
            updater.checkForUpdates(sheet: true)
            break
//        case DeepLinkActions.addFolder:
//            // Placeholder
//            break
//        case DeepLinkActions.removeFolder:
//            // Placeholder
//            break
//        case DeepLinkActions.addExcludeFolder:
//            // Placeholder
//            break
//        case DeepLinkActions.removeExcludeFolder:
//            // Placeholder
//            break
        case DeepLinkActions.refreshAppsList:
            reloadAppsList(appState: appState, fsm: fsm)
            break
        case DeepLinkActions.resetSettings:
            DispatchQueue.global(qos: .background).async {
                UserDefaults.standard.dictionaryRepresentation().keys.forEach(UserDefaults.standard.removeObject(forKey:))
            }
            break
        default:
            break
        }
    }

}
