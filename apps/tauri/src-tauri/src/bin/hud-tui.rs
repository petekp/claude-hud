use std::io;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseEventKind, MouseButton},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, BorderType, Gauge, Padding, Paragraph},
    Frame, Terminal,
};

use hud_core::{
    config::load_hud_config,
    sessions::load_session_states_file,
    types::SessionState,
};

#[derive(Clone)]
struct ProjectDisplay {
    name: String,
    path: String,
    state: SessionState,
    context_percent: Option<u32>,
    working_on: Option<String>,
    next_step: Option<String>,
    flash_until: Option<Instant>,
}

struct App {
    projects: Vec<ProjectDisplay>,
    selected: usize,
    hovered: Option<usize>,
    card_areas: Vec<Rect>,
    should_quit: bool,
    last_states_check: Instant,
    message: Option<(String, Instant)>,
}

impl App {
    fn new() -> Self {
        let mut app = Self {
            projects: Vec::new(),
            selected: 0,
            hovered: None,
            card_areas: Vec::new(),
            should_quit: false,
            last_states_check: Instant::now(),
            message: None,
        };
        app.load_projects();
        app
    }

    fn load_projects(&mut self) {
        use std::collections::HashMap;

        let config = load_hud_config();
        let states = load_session_states_file().unwrap_or_default();

        let old_states: HashMap<String, SessionState> = self.projects
            .iter()
            .map(|p| (p.path.clone(), p.state.clone()))
            .collect();

        self.projects = config
            .pinned_projects
            .iter()
            .map(|path| {
                let name = PathBuf::from(path)
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.clone());

                let entry = states.projects.get(path);
                let state = entry
                    .map(|e| parse_state(&e.state))
                    .unwrap_or(SessionState::Idle);

                let old_state = old_states.get(path);
                let flash_until = if old_state.is_some() && old_state != Some(&state) && state == SessionState::Ready {
                    Some(Instant::now() + Duration::from_millis(1500))
                } else {
                    self.projects.iter().find(|p| p.path == *path).and_then(|p| p.flash_until)
                };

                ProjectDisplay {
                    name,
                    path: path.clone(),
                    state,
                    context_percent: entry.and_then(|e| e.context.as_ref()).and_then(|c| c.percent_used),
                    working_on: entry.and_then(|e| e.working_on.clone()),
                    next_step: entry.and_then(|e| e.next_step.clone()),
                    flash_until,
                }
            })
            .collect();

        if self.selected >= self.projects.len() && !self.projects.is_empty() {
            self.selected = self.projects.len() - 1;
        }
    }

    fn refresh_states(&mut self) {
        if self.last_states_check.elapsed() > Duration::from_secs(2) {
            self.load_projects();
            self.last_states_check = Instant::now();
        }
    }

    fn select_next(&mut self) {
        if self.selected < self.projects.len().saturating_sub(1) {
            self.selected += 1;
        }
    }

    fn select_previous(&mut self) {
        if self.selected > 0 {
            self.selected -= 1;
        }
    }

    fn get_card_at_position(&self, row: u16) -> Option<usize> {
        for (i, area) in self.card_areas.iter().enumerate() {
            if row >= area.y && row < area.y + area.height {
                return Some(i);
            }
        }
        None
    }

    fn open_project(&mut self, resume: bool) {
        if let Some(project) = self.projects.get(self.selected) {
            let result = launch_in_tmux(&project.path, &project.name, resume);
            match result {
                Ok(_) => {
                    self.message = Some((
                        format!("Opened {} in tmux", project.name),
                        Instant::now() + Duration::from_secs(2),
                    ));
                }
                Err(e) => {
                    self.message = Some((
                        format!("Error: {}", e),
                        Instant::now() + Duration::from_secs(3),
                    ));
                }
            }
        }
    }

    fn set_message(&mut self, msg: String) {
        self.message = Some((msg, Instant::now() + Duration::from_secs(2)));
    }
}

fn parse_state(s: &str) -> SessionState {
    match s.to_lowercase().as_str() {
        "working" => SessionState::Working,
        "ready" => SessionState::Ready,
        "idle" => SessionState::Idle,
        "compacting" => SessionState::Compacting,
        "waiting" => SessionState::Waiting,
        _ => SessionState::Idle,
    }
}

fn launch_in_tmux(path: &str, name: &str, resume: bool) -> Result<(), String> {
    let in_tmux = std::env::var("TMUX").is_ok();

    if !in_tmux {
        return Err("Not running inside tmux".to_string());
    }

    let claude_cmd = if resume {
        "claude --resume"
    } else {
        "claude"
    };

    let window_name = name.replace('.', "-");

    Command::new("tmux")
        .args([
            "new-window",
            "-n", &window_name,
            "-c", path,
            claude_cmd,
        ])
        .output()
        .map_err(|e| format!("Failed to create tmux window: {}", e))?;

    Ok(())
}

fn main() -> io::Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new();
    let result = run_app(&mut terminal, &mut app);

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    terminal.show_cursor()?;

    if let Err(err) = result {
        eprintln!("Error: {err:?}");
    }

    Ok(())
}

fn run_app(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>, app: &mut App) -> io::Result<()> {
    loop {
        app.refresh_states();
        terminal.draw(|f| ui(f, app))?;

        if event::poll(Duration::from_millis(100))? {
            match event::read()? {
                Event::Key(key) if key.kind == KeyEventKind::Press => {
                    match key.code {
                        KeyCode::Char('q') | KeyCode::Esc => app.should_quit = true,
                        KeyCode::Down | KeyCode::Char('j') => app.select_next(),
                        KeyCode::Up | KeyCode::Char('k') => app.select_previous(),
                        KeyCode::Enter => app.open_project(false),
                        KeyCode::Char('r') => app.open_project(true),
                        KeyCode::Char('g') => app.selected = 0,
                        KeyCode::Char('G') => app.selected = app.projects.len().saturating_sub(1),
                        KeyCode::Char('R') => {
                            app.load_projects();
                            app.set_message("Refreshed".to_string());
                        }
                        _ => {}
                    }
                }
                Event::Mouse(mouse) => {
                    match mouse.kind {
                        MouseEventKind::Down(MouseButton::Left) => {
                            if let Some(idx) = app.get_card_at_position(mouse.row) {
                                if app.selected == idx {
                                    app.open_project(false);
                                } else {
                                    app.selected = idx;
                                }
                            }
                        }
                        MouseEventKind::ScrollDown => app.select_next(),
                        MouseEventKind::ScrollUp => app.select_previous(),
                        MouseEventKind::Moved => {
                            app.hovered = app.get_card_at_position(mouse.row);
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }

        if app.should_quit {
            return Ok(());
        }
    }
}

fn ui(f: &mut Frame, app: &mut App) {
    let area = f.area();

    let main_block = Block::default()
        .title(Line::from(vec![
            Span::styled(" ◆ ", Style::default().fg(Color::Cyan)),
            Span::styled("Claude HUD ", Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
            Span::styled(
                format!("({} projects) ", app.projects.len()),
                Style::default().fg(Color::DarkGray)
            ),
        ]))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::DarkGray));

    let inner = main_block.inner(area);
    f.render_widget(main_block, area);

    if app.projects.is_empty() {
        let empty_msg = Paragraph::new(vec![
            Line::from(""),
            Line::from(Span::styled(
                "No pinned projects found",
                Style::default().fg(Color::DarkGray)
            )),
            Line::from(""),
            Line::from(Span::styled(
                "Add projects in the Tauri app or edit ~/.claude/hud.json",
                Style::default().fg(Color::DarkGray)
            )),
        ]);
        f.render_widget(empty_msg, inner);
        return;
    }

    let chunks = Layout::vertical([
        Constraint::Min(0),
        Constraint::Length(2),
    ]).split(inner);

    let cards_area = chunks[0];
    let footer_area = chunks[1];

    let card_height = 5u16;
    let card_spacing = 1u16;

    app.card_areas.clear();

    let mut y = cards_area.y;
    for (i, project) in app.projects.iter().enumerate() {
        if y + card_height > cards_area.y + cards_area.height {
            break;
        }

        let card_area = Rect {
            x: cards_area.x + 1,
            y,
            width: cards_area.width.saturating_sub(2),
            height: card_height,
        };

        app.card_areas.push(card_area);
        render_project_card(f, project, card_area, i == app.selected, app.hovered == Some(i));

        y += card_height + card_spacing;
    }

    // Footer with message or help
    let footer_content = if let Some((ref msg, until)) = app.message {
        if Instant::now() < until {
            Line::from(Span::styled(format!(" {}", msg), Style::default().fg(Color::Cyan)))
        } else {
            app.message = None;
            default_footer()
        }
    } else {
        default_footer()
    };

    f.render_widget(Paragraph::new(footer_content), footer_area);
}

fn default_footer() -> Line<'static> {
    Line::from(vec![
        Span::styled(" [↑↓/jk]", Style::default().fg(Color::DarkGray)),
        Span::styled(" Nav ", Style::default().fg(Color::Gray)),
        Span::styled(" [Enter]", Style::default().fg(Color::DarkGray)),
        Span::styled(" Open ", Style::default().fg(Color::Gray)),
        Span::styled(" [r]", Style::default().fg(Color::DarkGray)),
        Span::styled(" Resume ", Style::default().fg(Color::Gray)),
        Span::styled(" [R]", Style::default().fg(Color::DarkGray)),
        Span::styled(" Refresh ", Style::default().fg(Color::Gray)),
        Span::styled(" [q]", Style::default().fg(Color::DarkGray)),
        Span::styled(" Quit ", Style::default().fg(Color::Gray)),
    ])
}

fn render_project_card(f: &mut Frame, project: &ProjectDisplay, area: Rect, selected: bool, hovered: bool) {
    let is_flashing = project.flash_until.map(|t| Instant::now() < t).unwrap_or(false);

    let (status_icon, status_color) = match project.state {
        SessionState::Ready => ("●", Color::Green),
        SessionState::Working => ("◐", Color::Yellow),
        SessionState::Idle => ("○", Color::DarkGray),
        SessionState::Compacting => ("◑", Color::Magenta),
        SessionState::Waiting => ("◉", Color::Blue),
    };

    let border_color = if is_flashing {
        Color::Green
    } else if selected {
        Color::Cyan
    } else if hovered {
        Color::Gray
    } else {
        Color::DarkGray
    };

    let border_style = Style::default().fg(border_color);
    let border_style = if selected || is_flashing {
        border_style.add_modifier(Modifier::BOLD)
    } else {
        border_style
    };

    let border_type = if selected || is_flashing {
        BorderType::Thick
    } else {
        BorderType::Rounded
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(border_type)
        .border_style(border_style)
        .padding(Padding::horizontal(1));

    let inner = block.inner(area);
    f.render_widget(block, area);

    let status_text = match project.state {
        SessionState::Ready => "Ready",
        SessionState::Working => "Working",
        SessionState::Idle => "Idle",
        SessionState::Compacting => "Compacting",
        SessionState::Waiting => "Waiting",
    };

    // Line 1: Name + status
    let line1 = Line::from(vec![
        Span::styled(format!("{} ", status_icon), Style::default().fg(status_color)),
        Span::styled(&project.name, Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
        Span::raw("  "),
        Span::styled(status_text, Style::default().fg(status_color)),
    ]);

    // Line 2: Working on or next step
    let line2_text = if let Some(ref working) = project.working_on {
        format!("  {}", truncate_string(working, inner.width as usize - 4))
    } else if let Some(ref next) = project.next_step {
        format!("  Next: {}", truncate_string(next, inner.width as usize - 10))
    } else {
        "  ".to_string()
    };
    let line2 = Line::from(Span::styled(line2_text, Style::default().fg(Color::Gray)));

    // Line 3: Path (dimmed)
    let display_path = project.path.replace(dirs::home_dir().map(|h| h.to_string_lossy().to_string()).unwrap_or_default().as_str(), "~");
    let line3 = Line::from(Span::styled(
        format!("  {}", truncate_string(&display_path, inner.width as usize - 4)),
        Style::default().fg(Color::DarkGray),
    ));

    if inner.height >= 1 {
        f.render_widget(Paragraph::new(line1), Rect { height: 1, ..inner });
    }
    if inner.height >= 2 {
        f.render_widget(Paragraph::new(line2), Rect { y: inner.y + 1, height: 1, ..inner });
    }
    if inner.height >= 3 {
        f.render_widget(Paragraph::new(line3), Rect { y: inner.y + 2, height: 1, ..inner });
    }

    // Context gauge on the right
    if let Some(pct) = project.context_percent {
        let bar_width = 10;
        let bar_x = area.x + area.width - bar_width - 2;
        let bar_area = Rect {
            x: bar_x,
            y: area.y + 1,
            width: bar_width,
            height: 1,
        };

        let bar_color = if pct > 80 {
            Color::Red
        } else if pct > 60 {
            Color::Yellow
        } else {
            Color::Green
        };

        let gauge = Gauge::default()
            .gauge_style(Style::default().fg(bar_color).bg(Color::DarkGray))
            .ratio(pct as f64 / 100.0)
            .label(format!("{}%", pct));

        f.render_widget(gauge, bar_area);
    }
}

fn truncate_string(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else if max_len > 3 {
        format!("{}...", &s[..max_len - 3])
    } else {
        s[..max_len].to_string()
    }
}
