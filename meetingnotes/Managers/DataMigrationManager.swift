// DataMigrationManager.swift
// Handles data migration between different app versions

import Foundation

/// Manages data migration between different app versions
class DataMigrationManager {
    static let shared = DataMigrationManager()
    
    private let userDefaults = UserDefaults.standard
    private let migrationKey = "hasPerformedProviderMigration"

    private init() {}

    /// Performs all necessary migrations on app launch
    func performMigrations() {
        migrateToMultiProvider()
    }

    /// Migrates from single OpenAI key to multi-provider key storage
    func migrateToMultiProvider() {
        // Check if migration has already been performed
        guard !userDefaults.bool(forKey: migrationKey) else {
            return
        }

        print("🔄 Starting multi-provider migration...")

        // Check if legacy key exists
        if let legacyKey = KeychainHelper.shared.get(forKey: "openAIKey"), !legacyKey.isEmpty {
            print("📝 Found legacy OpenAI key, migrating to new format...")

            // Save to new format
            let success = KeychainHelper.shared.saveAPIKey(legacyKey, for: .openai)

            if success {
                print("✅ Successfully migrated OpenAI key to new format")
                // Keep legacy key for backward compatibility (will remove in future version)
            } else {
                print("❌ Failed to migrate OpenAI key")
            }
        } else {
            print("ℹ️ No legacy OpenAI key found, skipping migration")
        }

        // Mark migration as complete
        userDefaults.set(true, forKey: migrationKey)
        print("✅ Multi-provider migration complete")
    }

    /// Migrates a meeting from an older version to the current version
    /// - Parameter meeting: The meeting to migrate
    /// - Returns: The migrated meeting, or nil if migration failed
    func migrateMeeting(_ meeting: Meeting) -> Meeting? {
        // No releases prior to version 1 – any older file is considered unsupported.
        guard meeting.dataVersion >= 1 else {
            print("🚫 Cannot migrate meeting \(meeting.id) – unsupported data version \(meeting.dataVersion)")
            return nil
        }

        var migratedMeeting = meeting

        // Migrate from version 1 to version 2
        if migratedMeeting.dataVersion < 2 {
            migratedMeeting = migrateV1ToV2(migratedMeeting)
        }

        // Future migrations can be added here as additional if statements
        // if migratedMeeting.dataVersion < 3 {
        //     migratedMeeting = migrateV2ToV3(migratedMeeting)
        // }

        return migratedMeeting
    }

    /// Migrates a meeting from version 1 to version 2
    /// Version 2 adds language support
    /// - Parameter meeting: The meeting to migrate
    /// - Returns: The migrated meeting
    private func migrateV1ToV2(_ meeting: Meeting) -> Meeting {
        print("🔄 Migrating meeting \(meeting.id) from v1 to v2 (adding language)")
        var migratedMeeting = meeting
        // Set language to English for existing meetings
        migratedMeeting.language = .english
        migratedMeeting.dataVersion = 2
        print("✅ Migrated meeting \(meeting.id) to v2 with language: English")
        return migratedMeeting
    }
    
    // Future migrateXToVersionY helpers will go here as needed
    
    /// Performs a backup of the meetings directory before migration
    /// - Returns: The backup directory URL, or nil if backup failed
    func backupMeetingsDirectory() -> URL? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let meetingsDirectory = documentsDirectory.appendingPathComponent("Meetings")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        
        let backupDirectory = documentsDirectory.appendingPathComponent("Meetings_Backup_\(timestamp)")
        
        do {
            try FileManager.default.copyItem(at: meetingsDirectory, to: backupDirectory)
            print("✅ Created backup at: \(backupDirectory)")
            return backupDirectory
        } catch {
            print("❌ Failed to create backup: \(error)")
            return nil
        }
    }
} 