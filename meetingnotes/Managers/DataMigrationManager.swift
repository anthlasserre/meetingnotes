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

        // Future migrations can be added here as `switch` cases.
        if meeting.dataVersion < Meeting.currentDataVersion {
            print("⚠️ No migration path for versions \(meeting.dataVersion + 1)...\(Meeting.currentDataVersion)")
            return nil
        }

        return meeting
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