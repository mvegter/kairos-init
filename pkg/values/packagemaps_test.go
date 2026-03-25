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
