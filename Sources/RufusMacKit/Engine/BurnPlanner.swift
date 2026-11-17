import Foundation

/// The high-level operation the user is performing.
public enum BurnMode: String, CaseIterable, Sendable, Identifiable {
    case single = "Single ISO"
    case multiboot = "Multiboot"
    case dd = "DD Image"
    case reclaim = "Reclaim"
    public var id: String { rawValue }
}

/// One labelled command in a burn pipeline.
public struct BurnStep: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let command: String
    public init(_ title: String, _ command: String) {
        self.id = UUID()
        self.title = title
        self.command = command
    }
}

/// A complete, auditable plan for a burn: a summary, any warnings, and the
/// ordered shell steps. `script` is what `PrivilegedRunner` executes (or, in
/// dry-run mode, previews) behind a single admin prompt.
public struct BurnPlan: Sendable {
    public let mode: BurnMode
    public let summary: String
    public let warnings: [String]
    public let steps: [BurnStep]
    public let experimental: Bool
    /// When set, the unprivileged app streams this file into a FIFO so the
    /// root script never reads protected folders (e.g. ~/Downloads) itself.
    public var feedImage: URL? = nil

    public var script: String {
        steps
            .map { "echo \"==> \($0.title)\"\n\($0.command)" }
            .joined(separator: "\n\n")
    }
}

/// Generates the command pipeline for every supported operation. This is the
/// heart of RufusMac — equivalent to Rufus's write engine, expressed as
/// auditable macOS shell using `diskutil`/`hdiutil`/`dd` plus bundled tools.
public struct BurnPlanner: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths = .resolve(thirdPartyDir: nil)) {
        self.tools = tools
    }

    public static let feedToken = "@@IMAGE_FIFO@@"
    public static let hashToken = "@@IMAGE_SHA@@"
    private var feedToken: String { Self.feedToken }
    private var hashToken: String { Self.hashToken }

    /// Single-quote a string for safe shell embedding.
    private func q(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func makePlan(mode: BurnMode, image: BootImage?, drive: USBDrive, config: WriteConfig) -> BurnPlan {
        switch mode {
        case .reclaim:
            return reclaimPlan(drive: drive, config: config)
        case .multiboot:
            return multibootPlan(drive: drive, config: config)
        case .dd:
            return rawWritePlan(image: image, drive: drive, config: config)
        case .single:
            if let image, image.kind == .windows {
                return windowsPlan(image: image, drive: drive, config: config)
            }
            return rawWritePlan(image: image, drive: drive, config: config)
        }
    }

    // MARK: - Raw / Linux / hybrid (dd)

    private func rawWritePlan(image: BootImage?, drive: USBDrive, config: WriteConfig) -> BurnPlan {
        guard let image else {
            return BurnPlan(mode: .dd, summary: "No image selected.", warnings: ["Select an image first."], steps: [], experimental: false)
        }
        var steps: [BurnStep] = []
        steps.append(BurnStep("Unmount \(drive.id)",
            "\(tools.diskutil) unmountDisk force \(drive.deviceNode)"))
        steps.append(BurnStep("Write image with dd (raw)",
            "\(tools.dd) if=\(feedToken) of=\(q(drive.rawDeviceNode)) bs=4m"))
        steps.append(BurnStep("Flush buffers", "sync"))
        if config.verifyAfterWrite {
            steps.append(BurnStep("Verify (compare SHA-256 of written bytes)",
                "SRC=$(cat \(hashToken)); " +
                "DST=$(\(tools.dd) if=\(q(drive.rawDeviceNode)) bs=4m count=$(( ( \(image.sizeBytes) + 4194303 ) / 4194304 )) 2>/dev/null | head -c \(image.sizeBytes) | \(tools.shasum) -a 256 | cut -d' ' -f1) || true; " +
                "[ \"$SRC\" = \"$DST\" ] && echo 'Verify OK' || (echo 'Verify FAILED' && exit 1)"))
        }
        steps.append(BurnStep("Eject \(drive.id)", "\(tools.diskutil) eject \(drive.deviceNode) || true"))

        var plan = BurnPlan(
            mode: .dd,
            summary: "Write \(image.name) (\(image.displaySize)) byte-for-byte to \(drive.title) (\(drive.displaySize)).",
            warnings: ["ALL DATA on \(drive.title) (\(drive.id)) will be ERASED."],
            steps: steps,
            experimental: false
        )
        plan.feedImage = image.url
        return plan
    }

    // MARK: - Windows (FAT32 + WIM split + Win11 bypass)

    private func windowsPlan(image: BootImage, drive: USBDrive, config: WriteConfig) -> BurnPlan {
        let label = config.sanitizedLabel.isEmpty ? "WIN_USB" : config.sanitizedLabel
        let slice = "\(drive.id)s1"
        let isoMount = "/tmp/rufusmac-winiso"
        var steps: [BurnStep] = []
        var warnings = ["ALL DATA on \(drive.title) (\(drive.id)) will be ERASED."]

        steps.append(BurnStep("Unmount \(drive.id)",
            "\(tools.diskutil) unmountDisk force \(drive.deviceNode)"))
        steps.append(BurnStep("Format \(label) as FAT32 (bootable for UEFI)",
            "\(tools.diskutil) eraseDisk \"MS-DOS FAT32\" \(q(label)) MBRFormat \(drive.deviceNode)"))
        steps.append(BurnStep("Resolve new volume mount point",
            "VOL=$(\(tools.diskutil) info -plist \(slice) | /usr/bin/plutil -extract MountPoint raw -o - -)"))
        steps.append(BurnStep("Mount Windows ISO read-only",
            "mkdir -p \(isoMount); \(tools.hdiutil) attach -readonly -nobrowse -noverify -mountpoint \(isoMount) \(q(image.url.path))"))
        steps.append(BurnStep("Copy Windows files (excluding install.wim)",
            "\(tools.rsync) -a --exclude=sources/install.wim \(isoMount)/ \"$VOL\"/"))

        if image.hasOversizedWIM {
            warnings.append("install.wim exceeds 4 GB — it will be split into .swm files for FAT32 (handled automatically).")
            steps.append(BurnStep("Split install.wim → install.swm (FAT32-safe)",
                "\(tools.wimlib) split \(isoMount)/sources/install.wim \"$VOL\"/sources/install.swm 3800"))
        } else {
            steps.append(BurnStep("Copy install.wim",
                "\(tools.rsync) -a \(isoMount)/sources/install.wim \"$VOL\"/sources/install.wim"))
        }

        if config.windows11Bypass {
            steps.append(BurnStep("Inject Windows 11 bypass (TPM/SecureBoot/RAM/CPU + local account)",
                "cat > \"$VOL\"/autounattend.xml <<'RMEOF'\n\(autounattendBypassXML)\nRMEOF"))
        }

        steps.append(BurnStep("Detach ISO", "\(tools.hdiutil) detach \(isoMount) -force || true"))
        steps.append(BurnStep("Eject \(drive.id)", "\(tools.diskutil) eject \(drive.deviceNode) || true"))

        return BurnPlan(
            mode: .single,
            summary: "Create a Windows installer USB on \(drive.title) from \(image.name)\(config.windows11Bypass ? " with Windows 11 requirement bypass" : "").",
            warnings: warnings,
            steps: steps,
            experimental: false
        )
    }

    // MARK: - Reclaim (restore to a normal usable disk)

    private func reclaimPlan(drive: USBDrive, config: WriteConfig) -> BurnPlan {
        let label = config.sanitizedLabel.isEmpty ? "USB" : config.sanitizedLabel
        let fsToken = config.fileSystem == .fat32 ? "MS-DOS FAT32" : config.fileSystem.diskutilToken
        let step = BurnStep("Erase \(drive.id) → single \(config.fileSystem.rawValue) volume",
            "\(tools.diskutil) eraseDisk \(q(fsToken)) \(q(label)) \(config.partitionScheme.diskutilToken) \(drive.deviceNode)")
        return BurnPlan(
            mode: .reclaim,
            summary: "Reclaim \(drive.title) (\(drive.displaySize)) as a normal, usable \(config.fileSystem.rawValue) drive labelled \(label).",
            warnings: ["ALL DATA on \(drive.title) (\(drive.id)) will be ERASED."],
            steps: [step],
            experimental: false
        )
    }

    // MARK: - Multiboot (Ventoy-style — experimental on macOS)

    private func multibootPlan(drive: USBDrive, config: WriteConfig) -> BurnPlan {
        var steps: [BurnStep] = []
        steps.append(BurnStep("Unmount \(drive.id)",
            "\(tools.diskutil) unmountDisk force \(drive.deviceNode)"))
        steps.append(BurnStep("Create Ventoy-style exFAT data partition",
            "\(tools.diskutil) eraseDisk ExFAT VENTOY GPT \(drive.deviceNode)"))
        steps.append(BurnStep("Install Ventoy boot files (bundled)",
            "\(q(tools.ventoyDir))/ventoy_mac_install.sh \(drive.deviceNode)"))
        if config.persistenceMB > 0 {
            steps.append(BurnStep("Create persistence data file (\(config.persistenceMB) MB)",
                "\(tools.dd) if=/dev/zero of=\"/Volumes/VENTOY/persistence.dat\" bs=1m count=\(config.persistenceMB); " +
                "\(tools.mke2fs) -t ext4 -L casper-rw -F \"/Volumes/VENTOY/persistence.dat\""))
        }
        steps.append(BurnStep("Done", "echo 'Now drag any number of ISO/WIM/IMG files onto the VENTOY drive and boot any of them.'"))

        return BurnPlan(
            mode: .multiboot,
            summary: "Set up \(drive.title) as a Ventoy-style multiboot drive — then just copy ISOs onto it and boot any one from a menu.",
            warnings: [
                "ALL DATA on \(drive.title) (\(drive.id)) will be ERASED.",
                "Multiboot on macOS is EXPERIMENTAL — Ventoy has no official macOS installer; RufusMac replicates the layout from the bundled Ventoy release."
            ],
            steps: steps,
            experimental: true
        )
    }

    // MARK: - Windows 11 bypass unattend

    private var autounattendBypassXML: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" language="neutral" versionScope="nonSxS" publicKeyToken="31bf3856ad364e35" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        </unattend>
        """
    }
}
