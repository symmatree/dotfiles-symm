// Cubie A7S overlay installer, modeled on siderolabs/sbc-allwinner's pine64
// installer (MPL-2.0).

package main

import (
	"context"
	_ "embed"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"

	"github.com/siderolabs/go-copy/copy"
	"github.com/siderolabs/talos/pkg/machinery/overlay"
	"github.com/siderolabs/talos/pkg/machinery/overlay/adapter"
	"golang.org/x/sys/unix"
)

const (
	// The A733 boot ROM reads the SPL from sector 256.
	off int64 = 256 * 512
	dtb       = "allwinner/sun60i-a733-cubie-a7s.dtb"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	adapter.Execute(ctx, &CubieA7SInstaller{})
}

type CubieA7SInstaller struct{}

type cubieA7SExtraOptions struct{}

func (i *CubieA7SInstaller) GetOptions(_ context.Context, extra cubieA7SExtraOptions) (overlay.Options, error) {
	return overlay.Options{
		Name: "cubie_a7s",
		KernelArgs: []string{
			"console=ttyS0,115200",
			"sysctl.kernel.kexec_load_disabled=1",
			"talos.dashboard.disabled=1",
		},
		PartitionOptions: overlay.PartitionOptions{
			// 16 MiB, past the end of u-boot-sunxi-with-spl.bin at 128 KiB.
			Offset: 32768,
		},
	}, nil
}

func (i *CubieA7SInstaller) Install(_ context.Context, options overlay.InstallOptions[cubieA7SExtraOptions]) error {
	f, err := os.OpenFile(options.InstallDisk, os.O_RDWR|unix.O_CLOEXEC, 0o666)
	if err != nil {
		return fmt.Errorf("failed to open %s: %w", options.InstallDisk, err)
	}

	defer f.Close() //nolint:errcheck

	uboot, err := os.ReadFile(filepath.Join(options.ArtifactsPath, "arm64/u-boot/cubie_a7s/u-boot-sunxi-with-spl.bin"))
	if err != nil {
		return err
	}

	if _, err = f.WriteAt(uboot, off); err != nil {
		return err
	}

	// NB: sync so a loopback device has the write before it is detached.
	if err = f.Sync(); err != nil {
		return err
	}

	src := filepath.Join(options.ArtifactsPath, "arm64/dtb", dtb)
	dst := filepath.Join(options.MountPrefix, "/boot/EFI/dtb", dtb)

	if err = os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}

	return copy.File(src, dst)
}
