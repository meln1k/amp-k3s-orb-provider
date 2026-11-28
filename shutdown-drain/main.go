// A burst machine's shutdown waits until its orbs are paused and their snapshots are on the server
// (docs/reference.md, Machine roles). amp-orbs-shutdown-drain runs `shutdown-drain serve`
// (nixos.nix), with k3s, busctl, systemd-inhibit, fgconsole, chvt and setfont on its PATH.
//
// serve: uncordons the node if a drain of ours left it cordoned, then holds a logind delay lock
// for shutdown and runs `watch` under it.
// watch: polls logind's PreparingForShutdown; when a shutdown waits, drains the node and shows
// its progress on text console 12 (ui.go), then exits, which releases the lock. A cancelled
// shutdown uncordons the node and keeps watching under the same lock, so a shutdown right after
// it still drains.
//
// Its log lines go to the journal; the VM tests (tests/) match some of them.
package main

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	kubeconfig = "/var/lib/rancher/k3s/agent/kubelet.kubeconfig"
	cert       = "/var/lib/rancher/k3s/agent/client-kubelet.crt"
	console    = 12

	// The provider counts a cordoned node as draining: it pauses the orbs on it and deletes
	// their workers. Workers still there after deleteAfter are deleted; each pauses its orb as it
	// exits. After giveUpAfter, also while the API does not answer, the drain goes on without them.
	deleteAfter = 10 * time.Minute
	giveUpAfter = 20 * time.Minute
	// A snapshot's upload counts as unknown after this long without atelet's metric.
	metricGiveUp = 3 * time.Minute
	// Zero readings in a row, 5 s apart: longer than atelet waits before an upload.
	zerosNeeded = 3
	poll        = 5 * time.Second
)

var node string

func logf(format string, a ...any) { fmt.Printf(format+"\n", a...) }

func run(stdin io.Reader, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = stdin
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func kubectl(stdin io.Reader, args ...string) ([]byte, error) {
	return run(stdin, "k3s", append([]string{"kubectl", "--kubeconfig", kubeconfig, "--request-timeout=10s"}, args...)...)
}

type object struct {
	Metadata struct {
		Name              string            `json:"name"`
		Annotations       map[string]string `json:"annotations"`
		DeletionTimestamp *string           `json:"deletionTimestamp"`
	} `json:"metadata"`
	Spec struct {
		Unschedulable bool `json:"unschedulable"`
	} `json:"spec"`
}

func getJSON(v any, args ...string) error {
	out, err := kubectl(nil, append(args, "-o", "json")...)
	if err != nil {
		return err
	}
	return json.Unmarshal(out, v)
}

// The kubelet's identity, system:node:<name>, is the only Node it may change.
func nodeName() (string, error) {
	b, err := os.ReadFile(cert)
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(b)
	if block == nil {
		return "", errors.New("no PEM block in " + cert)
	}
	c, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", err
	}
	name, ok := strings.CutPrefix(c.Subject.CommonName, "system:node:")
	if !ok || name == "" {
		return "", fmt.Errorf("%s is not a kubelet certificate: %q", cert, c.Subject.CommonName)
	}
	return name, nil
}

// logind's PreparingForShutdown: "b true" while a shutdown waits for delay locks. Only an
// explicit answer counts, so a D-Bus hiccup neither starts nor cancels a drain.
func shutdownIs(want bool) bool {
	out, err := run(nil, "busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
		"org.freedesktop.login1.Manager", "PreparingForShutdown")
	return err == nil && strings.TrimSpace(string(out)) == "b "+strconv.FormatBool(want)
}

// Names of the orb workers' pods on this node, from the API.
func workers() ([]string, error) {
	var list struct{ Items []object }
	if err := getJSON(&list, "get", "pods", "-n", "amp-orbs", "-l", "ate.dev/worker-pool", "--field-selector", "spec.nodeName="+node); err != nil {
		return nil, err
	}
	names := make([]string, 0, len(list.Items))
	for _, p := range list.Items {
		names = append(names, p.Metadata.Name)
	}
	return names, nil
}

// Seconds the oldest snapshot on this node has waited to be uploaded, 0 when none.
func undurable() (int, error) {
	id, err := run(nil, "k3s", "crictl", "pods", "--namespace", "ate-system", "--name", "atelet", "--state", "ready", "-q")
	if err != nil {
		return 0, err
	}
	ids := strings.Fields(string(id))
	if len(ids) == 0 {
		return 0, errors.New("atelet is not ready")
	}
	out, err := run(nil, "k3s", "crictl", "inspectp", ids[0])
	if err != nil {
		return 0, err
	}
	var pod struct {
		Status struct{ Network struct{ IP string } }
	}
	if err := json.Unmarshal(out, &pod); err != nil || pod.Status.Network.IP == "" {
		return 0, fmt.Errorf("no IP for atelet: %v", err)
	}
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("http://" + pod.Status.Network.IP + ":9090/metrics")
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("atelet metrics: %s", resp.Status)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, err
	}
	const metric = "atelet_snapshot_undurable_age_max_seconds"
	for line := range strings.Lines(string(body)) {
		rest, ok := strings.CutPrefix(line, metric)
		if !ok || (rest == "" || (rest[0] != '{' && rest[0] != ' ')) {
			continue
		}
		f := strings.Fields(rest)
		age, err := strconv.ParseFloat(f[len(f)-1], 64)
		if err != nil {
			return 0, err
		}
		return int(age), nil
	}
	return 0, errors.New(metric + " is missing")
}

func uncordon() error {
	var n object
	if err := getJSON(&n, "get", "node", node); err != nil {
		return err
	}
	if n.Metadata.Annotations["amp-orbs/drained-by"] != "shutdown" {
		return nil
	}
	if _, err := kubectl(nil, "patch", "node", node, "--type", "merge", "-p",
		`{"spec":{"unschedulable":null},"metadata":{"annotations":{"amp-orbs/drained-by":null}}}`); err != nil {
		return err
	}
	logf("uncordoned %s", node)
	return nil
}

// Cordons the node, marked as ours, unless it already was cordoned (then a boot leaves it so).
// Someone cordoning it by hand during our drain still finds our mark, so a cancel or the next
// boot uncordons it.
func cordon() error {
	var n object
	if err := getJSON(&n, "get", "node", node); err != nil {
		return err
	}
	if n.Spec.Unschedulable {
		logf("%s was already cordoned", node)
		return nil
	}
	_, err := kubectl(nil, "patch", "node", node, "--type", "merge", "-p",
		`{"spec":{"unschedulable":true},"metadata":{"annotations":{"amp-orbs/drained-by":"shutdown"}}}`)
	return err
}

// Evicts this node's task pods, so their Jobs see a disruption, not a failure, and run them
// elsewhere (skills/deploying-k3s-apps, Compute tasks). Returns how many it evicted.
func evictTasks() int {
	var list struct{ Items []object }
	if err := getJSON(&list, "get", "pods", "-n", "tasks", "--field-selector", "spec.nodeName="+node); err != nil {
		logf("cannot list task pods: %v", err)
		return 0
	}
	n := 0
	for _, p := range list.Items {
		if p.Metadata.DeletionTimestamp != nil {
			continue
		}
		name := p.Metadata.Name
		body := fmt.Sprintf(`{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":%q,"namespace":"tasks"}}`, name)
		if _, err := kubectl(strings.NewReader(body), "create", "--raw", "/api/v1/namespaces/tasks/pods/"+name+"/eviction", "-f", "-"); err != nil {
			logf("cannot evict task pod %s: %v", name, err)
			continue
		}
		logf("evicted task pod %s", name)
		n++
	}
	return n
}

// The console that was on screen (the desktop's), to go back to after a cancelled shutdown.
var prevConsole string

func toConsole() {
	if out, err := run(nil, "timeout", "5", "fgconsole"); err == nil {
		if vt := strings.TrimSpace(string(out)); vt != strconv.Itoa(console) {
			prevConsole = vt
		}
	}
	// In the background, so a console that does not switch cannot hold up the drain.
	go func() {
		tty := fmt.Sprintf("/dev/tty%d", console)
		if font := os.Getenv("CONSOLE_FONT"); font != "" {
			_, _ = run(nil, "setfont", "-C", tty, font)
		}
		_, _ = run(nil, "timeout", "5", "chvt", strconv.Itoa(console))
	}()
}

func backConsole() {
	if prevConsole != "" {
		go run(nil, "timeout", "5", "chvt", prevConsole)
	}
}

// The shutdown was cancelled: uncordon, unless another shutdown begins meanwhile (watch then
// drains again), and go back to the desktop. The lock stays held throughout.
func cancel(ui *ui, st status) {
	logf("shutdown cancelled; uncordoning")
	st.phase = phaseCancelled
	ui.show(st)
	defer ui.stop()
	for {
		err := uncordon()
		if err == nil {
			break
		}
		if shutdownIs(true) {
			return
		}
		logf("cannot uncordon yet: %v", err)
		time.Sleep(poll)
	}
	time.Sleep(time.Second) // long enough to read
	backConsole()
}

// drain returns false when the shutdown was cancelled, true when it may go on.
func drain() bool {
	logf("shutdown: cordoning %s", node)
	for tries := 1; ; tries++ {
		err := cordon()
		if err == nil {
			break
		}
		if shutdownIs(false) {
			logf("shutdown cancelled before the node was cordoned")
			return false
		}
		if tries >= 6 {
			logf("the API does not answer (%v); shutting down without pausing orbs", err)
			return true
		}
		time.Sleep(10 * time.Second)
	}

	st := status{node: node, start: time.Now(), phase: phaseTasks}
	toConsole()
	ui := startUI(console)
	ui.show(st)
	st.tasks = evictTasks()
	st.phase = phasePause
	ui.show(st)

	deleted := false
	for {
		if shutdownIs(false) {
			cancel(ui, st)
			return false
		}
		el := time.Since(st.start)
		if el >= giveUpAfter {
			logf("orbs still not paused after %d s; going on without them", int(el.Seconds()))
			st.note = "Some orbs did not pause in 20 minutes; going on without them."
			break
		}
		w, err := workers()
		if err != nil {
			st.apiDown = true
			ui.show(st)
			time.Sleep(poll)
			continue
		}
		st.apiDown = false
		st.setWorkers(w)
		ui.show(st)
		if len(w) == 0 {
			break
		}
		if el >= deleteAfter && !deleted {
			logf("deleting workers: %s", strings.Join(w, " "))
			if _, err := kubectl(nil, append(append([]string{"delete", "pod", "-n", "amp-orbs"}, w...), "--wait=false")...); err == nil {
				deleted = true
				st.forced = true
			} else {
				logf("cannot delete workers: %v", err)
			}
		}
		if int(el.Seconds())%30 < 5 {
			logf("waiting for orbs to pause: %d workers left", len(w))
		}
		time.Sleep(poll)
	}
	logf("orbs paused after %d s; waiting for their snapshots to upload", int(time.Since(st.start).Seconds()))
	st.phase = phaseUpload
	st.age = -1
	ui.show(st)

	var unknownSince time.Time
	for st.zeros < zerosNeeded {
		if shutdownIs(false) {
			cancel(ui, st)
			return false
		}
		el := int(time.Since(st.start).Seconds())
		age, err := undurable()
		if err != nil {
			st.zeros, st.age = 0, -1
			if unknownSince.IsZero() {
				unknownSince = time.Now()
			}
			if time.Since(unknownSince) >= metricGiveUp {
				logf("ERROR: cannot read atelet_snapshot_undurable_age_max_seconds for 3 minutes (%v); shutting down without knowing whether snapshots are uploaded", err)
				st.phase = phaseDone
				st.note = "Cannot tell whether the snapshots are uploaded; shutting down."
				ui.show(st)
				ui.stop()
				return true
			}
		} else {
			unknownSince = time.Time{}
			st.age = age
			if age == 0 {
				st.zeros++
			} else {
				st.zeros = 0
				if el%30 < 5 {
					logf("oldest snapshot not uploaded yet: %d s old", age)
				}
			}
		}
		ui.show(st)
		if st.zeros < zerosNeeded {
			time.Sleep(poll)
		}
	}
	logf("snapshots uploaded after %d s; shutting down", int(time.Since(st.start).Seconds()))
	st.phase = phaseDone
	ui.show(st)
	ui.stop()
	return true
}

// Polled rather than subscribed to, so no shutdown can slip in before a subscription.
func watch() {
	for {
		if shutdownIs(true) && drain() {
			return
		}
		time.Sleep(2 * time.Second)
	}
}

func serve() {
	// Restarted after a drain while the shutdown still waits on other delay locks: keep the
	// node cordoned.
	if shutdownIs(true) {
		logf("shutting down; leaving %s cordoned", node)
		select {}
	}
	// Before taking the lock, so it cannot undo a drain that started meanwhile. Until the API
	// answers no orb can start here, so there is nothing to protect yet.
	for {
		err := uncordon()
		if err == nil {
			break
		}
		logf("cannot check the node yet: %v", err)
		time.Sleep(10 * time.Second)
	}
	self, err := os.Executable()
	if err != nil {
		fail(err)
	}
	inhibit, err := exec.LookPath("systemd-inhibit")
	if err != nil {
		fail(err)
	}
	fail(syscall.Exec(inhibit, []string{"systemd-inhibit", "--what=shutdown", "--mode=delay", "--who=amp-orbs",
		"--why=Pausing orbs and uploading their snapshots", self, "watch"}, os.Environ()))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 2 || (os.Args[1] != "serve" && os.Args[1] != "watch") {
		fmt.Fprintln(os.Stderr, "usage: shutdown-drain serve")
		os.Exit(2)
	}
	if os.Args[1] == "serve" {
		// The K3s agent writes it on its first start, after this service starts.
		for {
			if _, err := os.Stat(cert); err == nil {
				break
			}
			time.Sleep(poll)
		}
	}
	var err error
	if node, err = nodeName(); err != nil {
		fail(fmt.Errorf("cannot read the node name from the kubelet certificate: %w", err))
	}
	if os.Args[1] == "serve" {
		serve()
	} else {
		watch()
	}
}
