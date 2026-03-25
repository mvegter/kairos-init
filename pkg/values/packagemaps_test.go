package values

import (
	"testing"
)

func TestHasDistroKernelPackages(t *testing.T) {
	tests := []struct {
		name     string
		pm       PackageMap
		distro   Distro
		arch     Architecture
		expected bool
	}{
		{
			name:     "Oracle has arm64 kernel packages",
			pm:       KernelPackages,
			distro:   OracleLinux,
			arch:     ArchARM64,
			expected: true,
		},
		{
			name:     "Oracle has amd64 kernel packages",
			pm:       KernelPackages,
			distro:   OracleLinux,
			arch:     ArchAMD64,
			expected: true,
		},
		{
			name:     "Fedora has no distro-specific kernel packages (uses RedHatFamily)",
			pm:       KernelPackages,
			distro:   Fedora,
			arch:     ArchAMD64,
			expected: false,
		},
		{
			name:     "Rocky has no distro-specific kernel packages (uses RedHatFamily)",
			pm:       KernelPackages,
			distro:   RockyLinux,
			arch:     ArchAMD64,
			expected: false,
		},
		{
			name:     "Ubuntu has distro-specific kernel packages (ArchCommon)",
			pm:       KernelPackages,
			distro:   Ubuntu,
			arch:     ArchAMD64,
			expected: true,
		},
		{
			name:     "Debian has arch-specific kernel packages",
			pm:       KernelPackages,
			distro:   Debian,
			arch:     ArchARM64,
			expected: true,
		},
		{
			name:     "Unknown distro has no kernel packages",
			pm:       KernelPackages,
			distro:   Unknown,
			arch:     ArchAMD64,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := hasDistroKernelPackages(tt.pm, tt.distro, tt.arch)
			if result != tt.expected {
				t.Errorf("hasDistroKernelPackages(%v, %v): expected %v, got %v",
					tt.distro, tt.arch, tt.expected, result)
			}
		})
	}
}

func TestOracleKernelPackagesContent(t *testing.T) {
	// Verify Oracle amd64 uses generic RHEL kernel names
	amd64Pkgs := KernelPackages[OracleLinux][ArchAMD64]
	if len(amd64Pkgs) == 0 {
		t.Fatal("Oracle amd64 kernel packages should not be empty")
	}
	foundKernel := false
	for _, pkgs := range amd64Pkgs {
		for _, pkg := range pkgs {
			if pkg == "kernel" {
				foundKernel = true
			}
		}
	}
	if !foundKernel {
		t.Error("Oracle amd64 should include generic 'kernel' package")
	}

	// Verify Oracle arm64 uses UEK kernel names
	arm64Pkgs := KernelPackages[OracleLinux][ArchARM64]
	if len(arm64Pkgs) == 0 {
		t.Fatal("Oracle arm64 kernel packages should not be empty")
	}
	foundUEK := false
	for _, pkgs := range arm64Pkgs {
		for _, pkg := range pkgs {
			if pkg == "kernel-uek" {
				foundUEK = true
			}
		}
	}
	if !foundUEK {
		t.Error("Oracle arm64 should include 'kernel-uek' package")
	}

	// Verify Oracle arm64 does NOT include generic 'kernel' package
	for _, pkgs := range arm64Pkgs {
		for _, pkg := range pkgs {
			if pkg == "kernel" {
				t.Error("Oracle arm64 should NOT include generic 'kernel' package (only UEK)")
			}
		}
	}
}

func TestOracleKernelPackagesTrustedBootContent(t *testing.T) {
	// Verify trusted boot Oracle arm64 uses UEK kernel names
	arm64Pkgs := KernelPackagesTrustedBoot[OracleLinux][ArchARM64]
	if len(arm64Pkgs) == 0 {
		t.Fatal("Oracle arm64 trusted boot kernel packages should not be empty")
	}
	foundUEK := false
	for _, pkgs := range arm64Pkgs {
		for _, pkg := range pkgs {
			if pkg == "kernel-uek" {
				foundUEK = true
			}
		}
	}
	if !foundUEK {
		t.Error("Oracle arm64 trusted boot should include 'kernel-uek' package")
	}
}

func TestGetKernelRepoEnablements(t *testing.T) {
	tests := []struct {
		name          string
		system        System
		expectCount   int
		expectName    string // if expectCount > 0, check first entry Name
		expectHasRepo bool   // at least one repo enablement entry
	}{
		{
			name: "Oracle arm64 returns UEK repo enablement",
			system: System{
				Distro: OracleLinux,
				Arch:   ArchARM64,
			},
			expectCount:   1,
			expectName:    "Enable Oracle UEK repository for arm64 kernel",
			expectHasRepo: true,
		},
		{
			name: "Oracle amd64 returns no repo enablement",
			system: System{
				Distro: OracleLinux,
				Arch:   ArchAMD64,
			},
			expectCount:   0,
			expectHasRepo: false,
		},
		{
			name: "Fedora amd64 returns no repo enablement",
			system: System{
				Distro: Fedora,
				Arch:   ArchAMD64,
			},
			expectCount:   0,
			expectHasRepo: false,
		},
		{
			name: "Rocky amd64 returns no repo enablement",
			system: System{
				Distro: RockyLinux,
				Arch:   ArchAMD64,
			},
			expectCount:   0,
			expectHasRepo: false,
		},
		{
			name: "Ubuntu amd64 returns no repo enablement",
			system: System{
				Distro: Ubuntu,
				Arch:   ArchAMD64,
			},
			expectCount:   0,
			expectHasRepo: false,
		},
		{
			name: "Unknown distro returns no repo enablement",
			system: System{
				Distro: Unknown,
				Arch:   ArchAMD64,
			},
			expectCount:   0,
			expectHasRepo: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := GetKernelRepoEnablements(tt.system)
			if len(result) != tt.expectCount {
				t.Errorf("expected %d enablements, got %d", tt.expectCount, len(result))
			}
			if tt.expectHasRepo && len(result) > 0 {
				if result[0].Name != tt.expectName {
					t.Errorf("expected first enablement name %q, got %q", tt.expectName, result[0].Name)
				}
				if len(result[0].Commands) == 0 {
					t.Error("expected enablement to have commands")
				}
				if result[0].OsRegex == "" {
					t.Error("expected enablement to have OsRegex")
				}
			}
		})
	}
}

func TestKernelRepoEnablementsDataIntegrity(t *testing.T) {
	// Verify all entries in the KernelRepoEnablements map have required fields
	for distro, archMap := range KernelRepoEnablements {
		for arch, enablements := range archMap {
			for i, re := range enablements {
				if re.Name == "" {
					t.Errorf("KernelRepoEnablements[%v][%v][%d]: Name must not be empty", distro, arch, i)
				}
				if re.OsRegex == "" {
					t.Errorf("KernelRepoEnablements[%v][%v][%d]: OsRegex must not be empty", distro, arch, i)
				}
				if len(re.Commands) == 0 {
					t.Errorf("KernelRepoEnablements[%v][%v][%d]: Commands must not be empty", distro, arch, i)
				}
			}
		}
	}
}

func TestFedoraKernelPackagesUnchanged(t *testing.T) {
	// Fedora should still use RedHatFamily packages (no distro-specific entries)
	_, hasFedora := KernelPackages[Fedora]
	if hasFedora {
		t.Error("Fedora should NOT have distro-specific kernel packages; it should use RedHatFamily")
	}

	// RedHatFamily should still have the generic kernel packages
	rhPkgs := KernelPackages[RedHatFamily][ArchCommon]
	if len(rhPkgs) == 0 {
		t.Fatal("RedHatFamily ArchCommon kernel packages should not be empty")
	}
	foundKernel := false
	for _, pkgs := range rhPkgs {
		for _, pkg := range pkgs {
			if pkg == "kernel" {
				foundKernel = true
			}
		}
	}
	if !foundKernel {
		t.Error("RedHatFamily should include generic 'kernel' package")
	}
}
