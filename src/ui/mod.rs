//! The widget: a header with review filters, search and actions above a
//! scrolling table of pull requests.

mod menu;
mod row;
mod settings;
mod style;

pub use style::load as load_style;

use crate::github::{Pr, Status};
use crate::prefs::{Corner, Prefs, Settings};
use adw::prelude::*;
use gtk::{gio, glib, pango};
use row::{Avatars, Columns, Row, image, label};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::time::Instant;

pub const REVIEW_QUEUE_URL: &str = "https://github.com/pulls/review-requested";

/// Rows that fit in the body before it scrolls.
const VISIBLE_ROWS: usize = 7;
const ROW_HEIGHT: i32 = 30;
/// Highest `dN` animation-delay class in style.css.
const MAX_STAGGER: usize = 6;
/// How long the undo toast stays up.
const TOAST_SECONDS: u32 = 6;

pub fn open_uri(uri: &str) {
    if let Err(err) = gio::AppInfo::launch_default_for_uri(uri, None::<&gio::AppLaunchContext>) {
        eprintln!("couldn't open {uri}: {err}");
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Filter {
    All,
    Requested,
    ReReview,
    NewCommits,
    Done,
}

impl Filter {
    const TABS: [Filter; 5] = [
        Filter::All,
        Filter::Requested,
        Filter::ReReview,
        Filter::NewCommits,
        Filter::Done,
    ];

    fn title(self) -> &'static str {
        match self {
            Filter::All => "All",
            Filter::Requested => "Review",
            Filter::ReReview => "Re-review",
            Filter::NewCommits => "Updated",
            Filter::Done => "Closed",
        }
    }

    fn matches(self, pr: &Pr) -> bool {
        match self {
            Filter::All => pr.status != Status::Done,
            Filter::Requested => pr.status == Status::Requested,
            Filter::ReReview => pr.status == Status::ReReview,
            Filter::NewCommits => pr.status == Status::NewCommits,
            Filter::Done => pr.status == Status::Done,
        }
    }

    fn empty_text(self) -> (&'static str, &'static str) {
        match self {
            Filter::All => ("All caught up", "Nothing is waiting on your review."),
            Filter::Done => (
                "Nothing closed",
                "Merged and closed PRs stay here for a day.",
            ),
            _ => ("Nothing here", "No pull requests in this group."),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Page {
    Loading,
    List,
    Empty(Filter),
    NoMatches,
    Error,
}

/// A number that rolls to its new value instead of jumping.
struct Counter {
    label: gtk::Label,
    animation: adw::TimedAnimation,
}

impl Counter {
    fn new() -> Self {
        let label = label("", &["count", "mono"]);
        let target = adw::CallbackAnimationTarget::new({
            let label = label.clone();
            move |value| label.set_label(&format!("{}", value.round() as i64))
        });
        let animation = adw::TimedAnimation::new(&label, 0.0, 0.0, 600, target);
        animation.set_easing(adw::Easing::EaseOutExpo);
        Self { label, animation }
    }

    fn set(&self, value: usize) {
        let to = value as f64;
        let started = self.animation.state() != adw::AnimationState::Idle;
        if started && self.animation.value_to() == to {
            return;
        }
        let from = self.animation.value();
        self.animation.reset();
        self.animation.set_value_from(from);
        self.animation.set_value_to(to);
        self.animation.play();
    }
}

struct Tab {
    filter: Filter,
    button: gtk::Button,
    count: Counter,
}

pub struct Widget {
    pub window: gtk::ApplicationWindow,
    pub refresh_button: gtk::Button,
    card: gtk::Box,
    prefs: Rc<RefCell<Prefs>>,
    header: gtk::Stack,
    search_entry: gtk::Text,
    search_count: gtk::Label,
    /// Lowercased search text; empty when not searching.
    query: RefCell<String>,
    tabs: Vec<Tab>,
    filter: Cell<Filter>,
    prs: RefCell<Vec<Pr>>,
    stack: gtk::Stack,
    scroller: gtk::ScrolledWindow,
    state_page: gtk::Box,
    page: Cell<Page>,
    list: gtk::ListBox,
    rows: Rc<RefCell<Vec<Row>>>,
    /// Filter and row signatures currently on screen.
    shown: RefCell<(Filter, Vec<String>)>,
    avatars: Avatars,
    columns: Columns,
    updated: gtk::Label,
    toast: gtk::Revealer,
    toast_label: gtk::Label,
    /// Prefs as they were before the last undoable change.
    undo_state: RefCell<Option<Prefs>>,
    /// Bumped per toast so an older timeout can't dismiss a newer one.
    toast_generation: Rc<Cell<u32>>,
    last_update: Cell<Option<Instant>>,
    error: RefCell<Option<String>>,
}

impl Widget {
    pub fn new(app: &adw::Application, prefs: Rc<RefCell<Prefs>>) -> Rc<Self> {
        settings::apply_appearance(prefs.borrow().settings.appearance);

        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("Reviews")
            .default_width(760)
            .resizable(false)
            .decorated(false)
            .build();
        window.add_css_class("megalith-widgets");

        // Header: title, filter tabs, freshness and actions. Searching swaps
        // all of it for a single search field.
        let tabs_bar = gtk::Box::new(gtk::Orientation::Horizontal, 2);
        let header = &tabs_bar;

        let glyph = image("git-pull-request-symbolic", 14, &["glyph"]);
        glyph.set_margin_end(6);
        let title = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        title.append(&glyph);
        title.append(&label("Reviews", &["widget-title"]));
        let move_handle = gtk::WindowHandle::builder()
            .child(&title)
            .tooltip_text("Drag to move and save a custom position")
            .build();
        move_handle.set_cursor_from_name(Some("grab"));
        header.append(&move_handle);

        let tabs: Vec<Tab> = Filter::TABS
            .into_iter()
            .map(|filter| {
                let count = Counter::new();
                let content = gtk::Box::new(gtk::Orientation::Horizontal, 6);
                content.append(&label(filter.title(), &[]));
                content.append(&count.label);
                let button = gtk::Button::builder().child(&content).build();
                button.add_css_class("tab");
                header.append(&button);
                Tab {
                    filter,
                    button,
                    count,
                }
            })
            .collect();

        let updated = label("", &["updated", "mono"]);
        updated.set_hexpand(true);
        updated.set_xalign(1.0);
        updated.set_margin_end(6);
        header.append(&updated);

        let search_button = icon_button("search-symbolic", "Search (Ctrl+F)");
        search_button.set_action_name(Some("widget.search"));
        header.append(&search_button);
        let queue_button = icon_button("link-external-symbolic", "Open review queue on GitHub");
        queue_button.set_action_name(Some("app.open-queue"));
        header.append(&queue_button);
        let refresh_button = icon_button("sync-symbolic", "Refresh (Ctrl+R)");
        header.append(&refresh_button);
        let settings_button = gtk::MenuButton::builder()
            .child(&image("gear-symbolic", 14, &[]))
            .tooltip_text("Settings")
            .build();
        settings_button.add_css_class("icon-button");
        header.append(&settings_button);

        let search_icon = image("search-symbolic", 14, &["glyph"]);
        // A bare text field: SearchEntry would bring its own theme icons.
        let search_entry = gtk::Text::builder()
            .placeholder_text("Search titles, repositories, authors, #numbers")
            .hexpand(true)
            .build();
        search_entry.add_css_class("search");
        let search_count = label("", &["updated", "mono"]);
        let close_search = icon_button("x-symbolic", "Close search (Esc)");
        close_search.set_action_name(Some("widget.close-search"));
        let search_bar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        search_bar.append(&search_icon);
        search_bar.append(&search_entry);
        search_bar.append(&search_count);
        search_bar.append(&close_search);

        let header = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .transition_duration(160)
            .build();
        header.add_css_class("header");
        header.add_named(&tabs_bar, Some("tabs"));
        header.add_named(&search_bar, Some("search"));

        // Body: placeholder rows, the list, or an empty/error state.
        let loading = gtk::Box::new(gtk::Orientation::Vertical, 0);
        for index in 0..VISIBLE_ROWS {
            loading.append(&row::placeholder(index));
        }

        let list = gtk::ListBox::new();
        list.add_css_class("prs");
        list.set_selection_mode(gtk::SelectionMode::None);
        list.set_valign(gtk::Align::Start);

        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&list)
            .build();

        let state_page = gtk::Box::new(gtk::Orientation::Vertical, 0);
        state_page.set_valign(gtk::Align::Center);
        state_page.set_halign(gtk::Align::Center);

        let stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .transition_duration(200)
            .height_request(VISIBLE_ROWS as i32 * ROW_HEIGHT)
            .build();
        stack.add_named(&loading, Some("loading"));
        stack.add_named(&scroller, Some("list"));
        stack.add_named(&state_page, Some("state"));

        // Undo toast, floating over the bottom of the list.
        let toast_label = label("", &[]);
        toast_label.set_ellipsize(pango::EllipsizeMode::End);
        toast_label.set_max_width_chars(48);
        let undo_button = gtk::Button::builder()
            .label("Undo")
            .action_name("widget.undo")
            .build();
        undo_button.add_css_class("text-link");
        let toast_content = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        toast_content.add_css_class("toast");
        toast_content.append(&toast_label);
        toast_content.append(&undo_button);
        let toast = gtk::Revealer::builder()
            .child(&toast_content)
            .transition_type(gtk::RevealerTransitionType::SlideUp)
            .transition_duration(180)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::End)
            .build();

        let body = gtk::Overlay::builder().child(&stack).build();
        body.add_css_class("body");
        body.add_overlay(&toast);

        let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
        card.add_css_class("card");
        card.append(&header);
        card.append(&body);

        window.set_child(Some(&card));

        let rows: Rc<RefCell<Vec<Row>>> = Default::default();
        list.connect_row_activated({
            let rows = rows.clone();
            move |_, activated| {
                let rows = rows.borrow();
                if let Some(row) = rows.iter().find(|row| &row.widget == activated) {
                    open_uri(&row.url);
                }
            }
        });

        let widget = Rc::new(Self {
            window,
            refresh_button,
            card,
            prefs,
            header,
            search_entry,
            search_count,
            query: Default::default(),
            tabs,
            filter: Cell::new(Filter::All),
            prs: Default::default(),
            stack,
            scroller,
            state_page,
            page: Cell::new(Page::Loading),
            list,
            rows,
            shown: RefCell::new((Filter::All, Vec::new())),
            avatars: Avatars::default(),
            columns: Columns::default(),
            updated,
            toast,
            toast_label,
            undo_state: Default::default(),
            toast_generation: Default::default(),
            last_update: Cell::new(None),
            error: Default::default(),
        });

        widget.search_entry.connect_changed({
            let weak = Rc::downgrade(&widget);
            move |entry| {
                if let Some(widget) = weak.upgrade() {
                    widget.query.replace(entry.text().trim().to_lowercase());
                    widget.render();
                }
            }
        });
        let escape = gtk::EventControllerKey::new();
        escape.connect_key_pressed({
            let weak = Rc::downgrade(&widget);
            move |_, key, _, _| {
                if key != gtk::gdk::Key::Escape {
                    return glib::Propagation::Proceed;
                }
                if let Some(widget) = weak.upgrade() {
                    widget.close_search();
                }
                glib::Propagation::Stop
            }
        });
        widget.search_entry.add_controller(escape);

        menu::install_actions(&widget);
        menu::attach(&widget);
        settings_button.set_popover(Some(&settings::popover(&widget)));
        crate::desktop::attach_drag(&widget.window, &move_handle);

        for tab in &widget.tabs {
            let weak: Weak<Self> = Rc::downgrade(&widget);
            let filter = tab.filter;
            tab.button.connect_clicked(move |_| {
                if let Some(widget) = weak.upgrade() {
                    widget.select(filter);
                }
            });
        }
        widget.sync_tabs();
        widget
    }

    pub fn set_loading(&self, loading: bool) {
        self.refresh_button.set_sensitive(!loading);
        if loading {
            self.refresh_button.add_css_class("spinning");
        } else {
            self.refresh_button.remove_css_class("spinning");
        }
    }

    /// `prs` holds open PRs first, then recently closed ones.
    pub fn show(&self, prs: Vec<Pr>) {
        self.last_update.set(Some(Instant::now()));
        self.error.replace(None);
        if self.prefs.borrow_mut().prune(&prs) {
            self.prefs.borrow().save();
        }
        self.prs.replace(prs);
        self.refresh_view();
        self.tick();
    }

    pub fn show_error(&self, message: &str) {
        self.error.replace(Some(message.to_owned()));
        if self.last_update.get().is_none() {
            self.set_page(Page::Error, message);
        }
        self.tick();
    }

    /// Refreshes relative timestamps without touching the list structure.
    pub fn tick(&self) {
        for row in self.rows.borrow().iter() {
            row.tick();
        }

        let when = match self.last_update.get() {
            Some(last) if last.elapsed().as_secs() < 60 => "updated now".to_owned(),
            Some(last) => format!("updated {} ago", row::ago_secs(last.elapsed().as_secs())),
            None => String::new(),
        };
        self.updated.set_label(&when);

        // A failed refresh tints the refresh button rather than taking space.
        match &*self.error.borrow() {
            Some(error) => {
                self.refresh_button
                    .set_tooltip_text(Some(&format!("Couldn't refresh: {error}")));
                self.refresh_button.add_css_class("stale");
            }
            None => {
                self.refresh_button
                    .set_tooltip_text(Some("Refresh (Ctrl+R)"));
                self.refresh_button.remove_css_class("stale");
            }
        }
    }

    /// Applies a prefs change, saves it and re-renders. With a toast, the
    /// change can be undone for a few seconds.
    fn update_prefs(&self, toast: Option<String>, change: impl FnOnce(&mut Prefs)) {
        let before = self.prefs.borrow().clone();
        change(&mut self.prefs.borrow_mut());
        if *self.prefs.borrow() == before {
            return;
        }
        self.prefs.borrow().save();
        crate::desktop::sync_position(&self.window, &self.settings());
        self.refresh_view();

        if let Some(toast) = toast {
            self.undo_state.replace(Some(before));
            self.show_toast(&toast);
        }
    }

    fn update_settings(&self, change: impl FnOnce(&mut Settings)) {
        self.update_prefs(None, |prefs| change(&mut prefs.settings));
    }

    pub fn settings(&self) -> Settings {
        self.prefs.borrow().settings
    }

    pub fn set_position(&self, corner: Corner, x: i32, y: i32) {
        self.update_prefs(None, |prefs| {
            prefs.settings.corner = corner;
            prefs.settings.custom_x = x;
            prefs.settings.custom_y = y;
        });
    }

    fn undo(&self) {
        let Some(before) = self.undo_state.take() else {
            return;
        };
        self.prefs.replace(before);
        self.prefs.borrow().save();
        crate::desktop::sync_position(&self.window, &self.settings());
        self.refresh_view();
        self.toast.set_reveal_child(false);
    }

    fn show_toast(&self, text: &str) {
        self.toast_label.set_label(text);
        self.toast.set_reveal_child(true);

        let generation = self.toast_generation.get().wrapping_add(1);
        self.toast_generation.set(generation);
        let current = self.toast_generation.clone();
        let toast = self.toast.downgrade();
        glib::timeout_add_seconds_local_once(TOAST_SECONDS, move || {
            if current.get() == generation
                && let Some(toast) = toast.upgrade()
            {
                toast.set_reveal_child(false);
            }
        });
    }

    fn open_search(&self) {
        self.header.set_visible_child_name("search");
        self.search_entry.grab_focus();
    }

    fn close_search(&self) {
        self.header.set_visible_child_name("tabs");
        // Clearing fires `changed`, which re-renders the tab's list.
        self.search_entry.set_text("");
    }

    fn select(&self, filter: Filter) {
        if self.filter.replace(filter) != filter {
            self.scroller.vadjustment().set_value(0.0);
            self.refresh_view();
        }
    }

    fn refresh_view(&self) {
        // A tab that just emptied out falls back to "All".
        let filter = self.filter.get();
        if filter == Filter::Done && self.matching(filter).is_empty() {
            self.filter.set(Filter::All);
        }
        self.sync_tabs();
        self.render();
    }

    /// PRs for a tab: visible ones only, pinned first.
    fn matching(&self, filter: Filter) -> Vec<Pr> {
        let prefs = self.prefs.borrow();
        let mut matching: Vec<Pr> = self
            .prs
            .borrow()
            .iter()
            .filter(|pr| filter.matches(pr) && prefs.is_visible(pr))
            .cloned()
            .collect();
        // Pinned first, then by original order (most recently active).
        matching.sort_by_key(|pr| !prefs.is_pinned(pr));
        matching
    }

    /// While searching, every visible PR is a candidate regardless of tab.
    fn search_results(&self, query: &str) -> Vec<Pr> {
        let prefs = self.prefs.borrow();
        let mut matching: Vec<Pr> = self
            .prs
            .borrow()
            .iter()
            .filter(|pr| prefs.is_visible(pr) && matches_query(pr, query))
            .cloned()
            .collect();
        // Stable, so pinned PRs keep their relative order at the top.
        matching.sort_by_key(|pr| !prefs.is_pinned(pr));
        matching
    }

    fn sync_tabs(&self) {
        let loaded = self.last_update.get().is_some();
        for tab in &self.tabs {
            let count = self.matching(tab.filter).len();
            if loaded {
                tab.count.set(count);
            }
            // Closed only shows up when there is something in it.
            tab.button
                .set_visible(tab.filter != Filter::Done || count > 0);
            if tab.filter == self.filter.get() {
                tab.button.add_css_class("active");
            } else {
                tab.button.remove_css_class("active");
            }
        }
    }

    fn render(&self) {
        if self.last_update.get().is_none() {
            return;
        }
        let filter = self.filter.get();
        let query = self.query.borrow().clone();
        let prs = if query.is_empty() {
            self.matching(filter)
        } else {
            self.search_results(&query)
        };

        self.search_count.set_label(&if query.is_empty() {
            String::new()
        } else {
            format!("{} found", prs.len())
        });

        if prs.is_empty() {
            let page = if query.is_empty() {
                Page::Empty(filter)
            } else {
                Page::NoMatches
            };
            self.set_page(page, &query);
            self.shown.replace((filter, Vec::new()));
            return;
        }

        // Skipping identical renders keeps hover and scroll state stable.
        let prefs = self.prefs.borrow();
        let signatures: Vec<String> = prs
            .iter()
            .map(|pr| format!("{}|{}|{query}", row::signature(pr), prefs.is_pinned(pr)))
            .collect();
        drop(prefs);
        let (changed_filter, changed_rows) = {
            let (shown_filter, shown) = &*self.shown.borrow();
            (*shown_filter != filter, *shown != signatures)
        };
        if changed_filter || changed_rows {
            self.rebuild(&prs, changed_filter);
        }
        self.shown.replace((filter, signatures));
        self.set_page(Page::List, "");
    }

    /// Rows new to the screen slide in; on a tab switch, all of them do.
    fn rebuild(&self, prs: &[Pr], animate_all: bool) {
        let previous: Vec<String> = self
            .rows
            .borrow()
            .iter()
            .map(|row| row.id.clone())
            .collect();
        let prefs = self.prefs.borrow();
        let query = self.query.borrow();
        self.list.remove_all();

        let mut entering = 0;
        let rows: Vec<Row> = prs
            .iter()
            .map(|pr| {
                let row = Row::new(
                    pr,
                    self.avatars.get(pr),
                    prefs.is_pinned(pr),
                    &query,
                    &self.columns,
                );
                if animate_all || !previous.contains(&pr.id) {
                    row.widget.add_css_class("enter");
                    row.widget
                        .add_css_class(&format!("d{}", entering.min(MAX_STAGGER)));
                    entering += 1;
                }
                self.list.append(&row.widget);
                row
            })
            .collect();
        self.rows.replace(rows);
    }

    fn set_page(&self, page: Page, message: &str) {
        // Error and no-match pages carry a message, so they always refresh.
        if self.page.replace(page) == page && !matches!(page, Page::Error | Page::NoMatches) {
            return;
        }
        match page {
            Page::Loading => self.stack.set_visible_child_name("loading"),
            Page::List => self.stack.set_visible_child_name("list"),
            Page::Empty(filter) => {
                let (title, body) = filter.empty_text();
                let tone = if filter == Filter::All { "done" } else { "" };
                self.fill_state("check-circle-symbolic", tone, title, body);
                self.stack.set_visible_child_name("state");
            }
            Page::NoMatches => {
                let body = format!("Nothing matches “{message}”.");
                self.fill_state("search-symbolic", "", "No matches", &body);
                self.stack.set_visible_child_name("state");
            }
            Page::Error => {
                self.fill_state("alert-symbolic", "error", "Couldn't reach GitHub", message);
                self.stack.set_visible_child_name("state");
            }
        }
    }

    /// Rebuilt every time so the entrance animation replays.
    fn fill_state(&self, icon: &str, tone: &str, title: &str, body: &str) {
        while let Some(child) = self.state_page.first_child() {
            self.state_page.remove(&child);
        }

        let icon = image(icon, 22, &["state-icon"]);
        if !tone.is_empty() {
            icon.add_css_class(tone);
        }
        icon.set_margin_bottom(10);

        let title = label(title, &["state-title"]);
        title.set_xalign(0.5);

        let body = label(body, &["state-body"]);
        body.set_xalign(0.5);
        body.set_justify(gtk::Justification::Center);
        body.set_wrap(true);
        body.set_max_width_chars(60);
        body.set_margin_top(3);
        body.set_selectable(tone == "error");

        self.state_page.append(&icon);
        self.state_page.append(&title);
        self.state_page.append(&body);
    }
}

fn matches_query(pr: &Pr, query: &str) -> bool {
    let number = query.strip_prefix('#').unwrap_or(query);
    pr.title.to_lowercase().contains(query)
        || pr.repo.to_lowercase().contains(query)
        || pr.author.to_lowercase().contains(query)
        || pr.number.to_string() == number
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::builder()
        .child(&image(icon, 14, &[]))
        .tooltip_text(tooltip)
        .build();
    button.add_css_class("icon-button");
    button
}
