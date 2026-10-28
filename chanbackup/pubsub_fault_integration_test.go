package chanbackup

import (
	"errors"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/btcsuite/btcd/wire/v2"
	"github.com/lightningnetwork/lnd/keychain"
	"github.com/lightningnetwork/lnd/lnencrypt"
	"github.com/stretchr/testify/require"
)

// failOnceFile delegates reads and successful swaps to LND's real encrypted
// MultiFile. Each attempted swap is signalled after returning to SubSwapper.
// The one-shot failure models a transient disk write error before rename.
type failOnceFile struct {
	Swapper
	failNext atomic.Bool
	attempts chan error
}

func (f *failOnceFile) UpdateAndSwap(packed PackedMulti) error {
	var err error
	if f.failNext.Swap(false) {
		err = errors.New("injected transient backup write failure")
	} else {
		err = f.Swapper.UpdateAndSwap(packed)
	}
	f.attempts <- err
	return err
}

func waitBackupAttempt(t *testing.T, f *failOnceFile) error {
	t.Helper()
	select {
	case err := <-f.attempts:
		return err
	case <-time.After(10 * time.Second):
		t.Fatal("timed out awaiting encrypted backup write attempt")
		return nil
	}
}

func sendBackupEvent(t *testing.T, c *mockChannelNotifier, event ChannelEvent) {
	t.Helper()
	select {
	case c.chanEvents <- event:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out delivering channel event")
	}
}

func assertEncryptedDiskOutpoints(t *testing.T, f *failOnceFile,
	keyring keychain.KeyRing, want, absent wire.OutPoint) {

	t.Helper()
	multi, err := f.ExtractMulti(keyring)
	require.NoError(t, err)
	require.NotNil(t, multi)

	present := make(map[wire.OutPoint]struct{}, len(multi.StaticBackups))
	for _, single := range multi.StaticBackups {
		present[single.FundingOutpoint] = struct{}{}
	}

	require.Contains(t, present, want,
		"live channel must exist in successfully swapped encrypted SCB")
	require.NotContains(t, present, absent,
		"confirmed closed outpoint must not reappear after a failed swap")
}

// TestSubSwapperCloseFailureCannotResurrectDiskBackup is a predeclared
// negative control against the original SubSwapper implementation. On the
// unpatched upstream source this is expected to FAIL: A reappears on disk.
// Acceptance for a corrective implementation is a passing test with the
// genuine encrypted file and no remaining copy of A.
func TestSubSwapperCloseFailureCannotResurrectDiskBackup(t *testing.T) {
	keyring := &lnencrypt.MockKeyRing{}
	file := NewMultiFile(filepath.Join(t.TempDir(), DefaultBackupFileName), true)
	fault := &failOnceFile{
		Swapper:  file,
		attempts: make(chan error, 16),
	}
	notifier := newMockChannelNotifier()
	s, err := NewSubSwapper(t.Context(), nil, notifier, keyring, fault)
	require.NoError(t, err)
	require.NoError(t, s.Start())
	defer s.Stop()
	require.NoError(t, waitBackupAttempt(t, fault)) // Initial empty backup.

	original, err := genRandomOpenChannelShell()
	require.NoError(t, err)
	sendBackupEvent(t, notifier, ChannelEvent{
		NewChans: []ChannelWithAddrs{{OpenChannel: original}},
	})
	require.NoError(t, waitBackupAttempt(t, fault))

	// A is durably backed up before the injected write error.
	before, err := fault.ExtractMulti(keyring)
	require.NoError(t, err)
	require.Len(t, before.StaticBackups, 1)
	require.Equal(t, original.FundingOutpoint,
		before.StaticBackups[0].FundingOutpoint)

	fault.failNext.Store(true)
	sendBackupEvent(t, notifier, ChannelEvent{
		ClosedChans: []wire.OutPoint{original.FundingOutpoint},
	})
	require.Error(t, waitBackupAttempt(t, fault))

	unrelated, err := genRandomOpenChannelShell()
	require.NoError(t, err)
	sendBackupEvent(t, notifier, ChannelEvent{
		NewChans: []ChannelWithAddrs{{OpenChannel: unrelated}},
	})
	require.NoError(t, waitBackupAttempt(t, fault))

	assertEncryptedDiskOutpoints(t, fault, keyring,
		unrelated.FundingOutpoint, original.FundingOutpoint)
}
