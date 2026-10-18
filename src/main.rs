mod desktop;
mod github;
mod prefs;
mod ui;

use adw::prelude::*;
use chrono::{TimeDelta, Utc};
use github::{Pr, Snapshot, Status};
use gtk::{gio, glib};
use prefs::Prefs;
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::{Rc, Weak};
use std::time::{Duration, Instant};

const APP_ID: &str = "dev.megalith.MegalithWidgets";
/// How often timestamps update and the refresh interval is checked.
const TICK_INTERVAL: Duration = Duration::from_secs(15);
/// How long merged/closed PRs linger at the bottom of the list.
const KEEP_DONE_FOR: TimeDelta = TimeDelta::hours(24);

fn main() -> glib::ExitCode {
    gio::resources_register_include!("resources.gresource").expect("bundled resources are valid");

    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_startup(|app| {
        ui::load_style();
        install_app_actions(app);
    });
    app.connect_activate(activate);
    app.run()
}

fn install_app_actions(app: &adw::Application) {
    let open = gio::SimpleAction::new("open", Some(glib::VariantTy::STRING));
    open.connect_activate(|_, parameter| {
        if let Some(uri) = parameter.and_then(|value| value.get::<String>()) {
            ui::open_uri(&uri);
        }
    });
    app.add_action(&open);

    let open_queue = gio::SimpleAction::new("open-queue", None);
    open_queue.connect_activate(|_, _| ui::open_uri(ui::REVIEW_QUEUE_URL));
    app.add_action(&open_queue);

    let quit = gio::SimpleAction::new("quit", None);
    quit.connect_activate({
        let app = app.downgrade();
        move |_, _| {
            if let Some(app) = app.upgrade() {
                app.quit();
            }
        }
    });
    app.add_action(&quit);
    app.set_accels_for_action("app.quit", &["<Ctrl>q", "<Ctrl>w"]);
}

fn activate(app: &adw::Application) {
    if let Some(window) = app.active_window() {
        window.present();
        return;
    }

    let prefs = Rc::new(RefCell::new(Prefs::load()));
    let widget = Rc::new(Widget {
        app: app.clone(),
        view: ui::Widget::new(app, prefs.clone()),
        prefs,
        model: Default::default(),
        loading: Cell::new(false),
        last_fetch: Cell::new(None),
    });

    widget.view.refresh_button.connect_clicked({
        let widget = Rc::downgrade(&widget);
        move |_| with(&widget, Widget::refresh)
    });

    let refresh = gio::SimpleAction::new("refresh", None);
    refresh.connect_activate({
        let widget = Rc::downgrade(&widget);
        move |_, _| with(&widget, Widget::refresh)
    });
    app.add_action(&refresh);
    app.set_accels_for_action("app.refresh", &["<Ctrl>r", "F5"]);

    // The window owns the widget state and releases it when it is destroyed.
    widget.view.window.connect_destroy({
        let widget = widget.clone();
        move |_| {
            let _ = &widget;
        }
    });

    every(&widget, TICK_INTERVAL, |widget| {
        widget.view.tick();
        if widget.refresh_due() {
            widget.refresh();
        }
    });

    desktop::place(&widget.view.window);
    widget.view.window.present();
    widget.refresh();
}

#[derive(Default)]
struct Model {
    open: Vec<Pr>,
    done: HashMap<String, Pr>,
    /// Attention keys already announced; `None` until the first load so
    /// startup doesn't fire a notification for every waiting PR.
    announced: Option<HashSet<String>>,
}

struct Widget {
    app: adw::Application,
    view: Rc<ui::Widget>,
    prefs: Rc<RefCell<Prefs>>,
    model: RefCell<Model>,
    loading: Cell<bool>,
    last_fetch: Cell<Option<Instant>>,
}

impl Widget {
    fn refresh(self: &Rc<Self>) {
        if self.loading.replace(true) {
            return;
        }
        self.last_fetch.set(Some(Instant::now()));
        self.view.set_loading(true);

        let tracked: Vec<String> = self
            .model
            .borrow()
            .open
            .iter()
            .map(|pr| pr.id.clone())
            .collect();
        let widget = self.clone();
        glib::spawn_future_local(async move {
            let result = gio::spawn_blocking(move || github::fetch(tracked))
                .await
                .unwrap_or_else(|_| Err(anyhow::anyhow!("refresh thread panicked")));

            widget.loading.set(false);
            widget.view.set_loading(false);
            match result {
                Ok(snapshot) => widget.apply(snapshot),
                Err(err) => widget.view.show_error(&format!("{err:#}")),
            }
        });
    }

    fn refresh_due(&self) -> bool {
        let interval =
            Duration::from_secs(u64::from(self.view.settings().refresh_minutes.max(1)) * 60);
        self.last_fetch
            .get()
            .is_none_or(|last| last.elapsed() >= interval)
    }

    fn apply(&self, snapshot: Snapshot) {
        let mut model = self.model.borrow_mut();

        let now = Utc::now();
        for pr in snapshot.done {
            model.done.insert(pr.id.clone(), pr);
        }
        for pr in &snapshot.open {
            model.done.remove(&pr.id);
        }
        model.done.retain(|_, pr| {
            pr.closed_at
                .is_some_and(|closed| now - closed < KEEP_DONE_FOR)
        });

        self.announce(&mut model, &snapshot.open);
        model.open = snapshot.open;

        let mut done: Vec<&Pr> = model.done.values().collect();
        done.sort_by_key(|pr| std::cmp::Reverse(pr.closed_at));
        let visible: Vec<Pr> = model.open.iter().chain(done).cloned().collect();
        drop(model);

        self.view.show(visible);
    }

    fn announce(&self, model: &mut Model, open: &[Pr]) {
        let enabled = self.prefs.borrow().settings.notifications;
        if let Some(announced) = model.announced.as_ref().filter(|_| enabled) {
            let prefs = self.prefs.borrow();
            for pr in open
                .iter()
                .filter(|pr| !announced.contains(&pr.attention_key()) && !prefs.is_hidden(pr))
            {
                let title = match pr.status {
                    Status::Requested => "Review requested",
                    Status::ReReview => "Re-review requested",
                    Status::NewCommits => "New commits since your review",
                    Status::Done => continue,
                };
                let notification = gio::Notification::new(title);
                notification.set_body(Some(&format!(
                    "{}\n{} #{} · {}",
                    pr.title, pr.repo, pr.number, pr.author
                )));
                notification
                    .set_default_action_and_target_value("app.open", Some(&pr.url.to_variant()));
                self.app.send_notification(Some(&pr.id), &notification);
            }
        }
        model.announced = Some(open.iter().map(Pr::attention_key).collect());
    }
}

fn with(widget: &Weak<Widget>, f: impl FnOnce(&Rc<Widget>)) {
    if let Some(widget) = widget.upgrade() {
        f(&widget);
    }
}

/// Runs `f` on an interval for as long as the widget is alive.
fn every(widget: &Rc<Widget>, interval: Duration, f: impl Fn(&Rc<Widget>) + 'static) {
    let widget = Rc::downgrade(widget);
    glib::timeout_add_local(interval, move || match widget.upgrade() {
        Some(widget) => {
            f(&widget);
            glib::ControlFlow::Continue
        }
        None => glib::ControlFlow::Break,
    });
}
