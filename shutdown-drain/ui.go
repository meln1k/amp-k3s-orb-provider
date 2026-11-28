// The drain's progress on a text console: nothing else is on screen once the desktop session has
// ended. The Linux console shows the 16 basic colours, and its Terminus font has █ ░ √ • · and
// the plain box-drawing lines, but no ✓, ● or rounded corners, so the screen uses only those.
package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"charm.land/bubbles/v2/progress"
	"charm.land/bubbles/v2/spinner"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

type phase int

const (
	phaseTasks phase = iota
	phasePause
	phaseUpload
	phaseDone
	phaseCancelled
)

type worker struct {
	name   string
	paused bool
}

// What the drain has done so far; the screen draws it.
type status struct {
	node    string
	start   time.Time
	phase   phase
	tasks   int      // task pods evicted
	workers []worker // every orb worker seen on the node since the drain began
	apiDown bool     // the last worker listing failed
	forced  bool     // workers were deleted after deleteAfter
	age     int      // seconds the oldest snapshot has waited for its upload, -1 unknown
	zeros   int      // zero readings of age in a row
	note    string   // why the drain went on without finishing a step
}

// setWorkers marks the workers gone from the listing as paused. It builds a new slice, so a
// status already sent to the screen does not change under it.
func (s *status) setWorkers(names []string) {
	present := map[string]bool{}
	for _, n := range names {
		present[n] = true
	}
	ws := make([]worker, 0, len(s.workers)+len(names))
	for _, w := range s.workers {
		ws = append(ws, worker{w.name, w.paused || !present[w.name]})
		delete(present, w.name)
	}
	for _, n := range names {
		if present[n] {
			ws = append(ws, worker{name: n})
		}
	}
	s.workers = ws
}

func (s status) paused() int {
	n := 0
	for _, w := range s.workers {
		if w.paused {
			n++
		}
	}
	return n
}

type (
	tickMsg time.Time
	stopMsg struct{}
)

func tick() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

type model struct {
	st            status
	now           time.Time
	width, height int
	spin          spinner.Model
	bar           progress.Model
}

func (m model) Init() tea.Cmd { return tea.Batch(m.spin.Tick, tick()) }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case status:
		m.st = msg
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		// The clock stops with the drain.
		if m.st.phase < phaseDone {
			m.now = time.Time(msg)
		}
		return m, tick()
	case stopMsg:
		return m, tea.Quit
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd
	}
	return m, nil
}

var (
	bold    = lipgloss.NewStyle().Bold(true)
	dim     = lipgloss.NewStyle().Foreground(lipgloss.BrightBlack)
	green   = lipgloss.NewStyle().Foreground(lipgloss.Green)
	yellow  = lipgloss.NewStyle().Foreground(lipgloss.Yellow)
	red     = lipgloss.NewStyle().Foreground(lipgloss.Red)
	barSize = 44
	// Wide enough for the longest line, so the box keeps its size from step to step.
	textWidth = 66
	boxed     = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(lipgloss.Blue).Padding(1, 3)
)

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}

func (m model) View() tea.View {
	st := m.st
	var b strings.Builder
	line := func(s string) { b.WriteString(s + "\n") }

	el := m.now.Sub(st.start).Truncate(time.Second)
	if el < 0 {
		el = 0
	}
	title := bold.Render(st.node + " is shutting down")
	clock := dim.Render(fmt.Sprintf("%d:%02d", int(el.Minutes()), int(el.Seconds())%60))
	gap := max(2, textWidth-lipgloss.Width(title)-lipgloss.Width(clock))
	line(title + strings.Repeat(" ", gap) + clock)
	line("")

	// step draws one step: done before the current phase, active in it, pending after it.
	step := func(p phase, pending, active, done string) {
		switch {
		case st.phase == phaseCancelled && p >= phasePause:
			line(dim.Render("·  " + pending))
		case st.phase > p:
			line(green.Render("√") + "  " + done)
		case st.phase == p:
			line(yellow.Render(m.spin.View()) + "  " + bold.Render(active))
		default:
			line(dim.Render("·  " + pending))
		}
	}

	line(green.Render("√") + "  Stopped new orbs from starting here")
	tasksDone := "No task pods to move"
	if st.tasks > 0 {
		tasksDone = "Moved " + plural(st.tasks, "task pod", "task pods") + " elsewhere"
	}
	step(phaseTasks, "Move task pods elsewhere", "Moving task pods elsewhere", tasksDone)

	total, paused := len(st.workers), st.paused()
	pausing := fmt.Sprintf("Pausing orbs: %d left", total-paused)
	if st.apiDown {
		pausing = "Pausing orbs: the cluster does not answer"
	}
	pausedDone := "No orbs to pause"
	if total > 0 {
		pausedDone = "Paused " + plural(paused, "orb", "orbs")
	}
	step(phasePause, "Pause orbs", pausing, pausedDone)
	if st.phase == phasePause && total > 0 {
		line("   " + m.bar.ViewAs(float64(paused)/float64(total)) + "  " + fmt.Sprintf("%d of %d", paused, total))
		const shown = 8
		for i, w := range st.workers {
			if i == shown {
				line(dim.Render(fmt.Sprintf("   … and %d more", total-shown)))
				break
			}
			if w.paused {
				line("   " + green.Render("√") + " " + dim.Render(w.name))
			} else {
				line("   " + yellow.Render("•") + " " + w.name)
			}
		}
	}

	uploading := "Uploading snapshots: waiting for atelet"
	switch {
	case st.age > 0:
		uploading = fmt.Sprintf("Uploading snapshots: the oldest has waited %d s", st.age)
	case st.age == 0:
		uploading = fmt.Sprintf("Uploading snapshots: checking they are all on the server (%d/%d)", st.zeros, zerosNeeded)
	}
	step(phaseUpload, "Upload snapshots", uploading, "Uploaded snapshots")
	step(phaseDone, "Shut down", "Shutting down", "Shutting down")
	line("")

	switch st.phase {
	case phaseCancelled:
		line(yellow.Render("Shutdown cancelled.") + " Going back to the desktop.")
	case phaseDone:
		if st.note == "" {
			line(green.Render(fmt.Sprintf("All orbs paused and uploaded after %d s. Shutting down.", int(el.Seconds()))))
		}
	default:
		line(yellow.Render("Orbs on this machine are being paused and their snapshots"))
		line(yellow.Render("uploaded to the server. Please do not switch it off."))
		if st.forced {
			line(red.Render("Orbs not paused after 10 minutes are being stopped."))
		}
	}
	if st.note != "" {
		line(red.Render(st.note))
	}

	out := boxed.Render(lipgloss.NewStyle().Width(textWidth).Render(strings.TrimRight(b.String(), "\n")))
	if m.width > 0 && m.height > 0 {
		out = lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, out)
	}
	return tea.NewView(out)
}

// ui runs the screen on a text console. Without the console it does nothing.
type ui struct {
	p    *tea.Program
	done chan struct{}
}

func startUI(vt int) *ui {
	tty, err := os.OpenFile(fmt.Sprintf("/dev/tty%d", vt), os.O_WRONLY, 0)
	if err != nil {
		logf("no progress screen: %v", err)
		return &ui{}
	}
	m := model{
		now:  time.Now(),
		spin: spinner.New(spinner.WithSpinner(spinner.Line)),
		bar: progress.New(progress.WithWidth(barSize), progress.WithoutPercentage(),
			progress.WithFillCharacters('█', '░'), progress.WithColors(lipgloss.Green)),
	}
	m.bar.EmptyColor = lipgloss.BrightBlack
	u := &ui{done: make(chan struct{})}
	u.p = tea.NewProgram(m, tea.WithInput(nil), tea.WithOutput(tty), tea.WithoutSignalHandler(),
		tea.WithEnvironment([]string{"TERM=linux"}))
	go func() {
		defer close(u.done)
		defer tty.Close()
		if _, err := u.p.Run(); err != nil {
			logf("progress screen: %v", err)
		}
	}()
	return u
}

func (u *ui) show(st status) {
	if u.p != nil {
		u.p.Send(st)
	}
}

// stop draws the last status and leaves it on screen.
func (u *ui) stop() {
	if u.p == nil {
		return
	}
	u.p.Send(stopMsg{})
	select {
	case <-u.done:
	case <-time.After(5 * time.Second):
		u.p.Kill()
	}
	u.p = nil
}
