package ru.lifanx60.backupfixture;

import android.app.backup.BackupAgentHelper;
import android.app.backup.SharedPreferencesBackupHelper;

/** Synthetic agent for the disposable emulator, never Navitel. */
public final class SyntheticBackupAgent extends BackupAgentHelper {
    @Override public void onCreate() {
        addHelper("lab", new SharedPreferencesBackupHelper(this, "lab_probe"));
    }
}
