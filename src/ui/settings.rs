//! The settings popover behind the gear button.

use super::Widget;
use super::row::{image, label};
use crate::prefs::{Appearance, Corner, Settings};
use adw::prelude::*;
use std::rc::{Rc, Weak};

const REFRESH_CHOICES: [(u32, &str); 4] = [(1, "1m"), (2, "2m"), (5, "5m"), (15, "15m")];
const APPEARANCE_CHOICES: [(Appearance, &str); 3] = [
    (Appearance::System, "System"),
    (Appearance::Dark, "Dark"),
    (Appearance::Light, "Light"),
];
const POSITION_CHOICES: [(Corner, &str, &str); 5] = [
    (Corner::TopLeft, "Top left", "arrow-up-left-symbolic"),
    (Corner::TopRight, "Top right", "arrow-up-right-symbolic"),
    (
        Corner::BottomLeft,
        "Bottom left",
        "arrow-down-left-symbolic",
    ),
    (
        Corner::BottomRight,
        "Bottom right",
        "arrow-down-right-symbolic",
    ),
    (Corner::Custom, "Custom", "crosshairs-symbolic"),
];

pub fn apply_appearance(appearance: Appearance) {
    adw::StyleManager::default().set_color_scheme(match appearance {
        Appearance::System => adw::ColorScheme::Default,
        Appearance::Dark => adw::ColorScheme::ForceDark,
        Appearance::Light => adw::ColorScheme::ForceLight,
    });
}

pub fn popover(widget: &Rc<Widget>) -> gtk::Popover {
    let settings = widget.prefs.borrow().settings;
    let weak = Rc::downgrade(widget);

    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.append(&section_title("Settings"));
    content.append(&row(
        "Notifications",
        "Alert when a PR needs you again",
        &switch(&weak, settings.notifications, |settings, on| {
            settings.notifications = on
        }),
    ));
    content.append(&row(
        "Show drafts",
        "Include draft pull requests",
        &switch(&weak, settings.show_drafts, |settings, on| {
            settings.show_drafts = on
        }),
    ));
    content.append(&row(
        "Refresh every",
        "How often GitHub is checked",
        &segmented(
            &weak,
            &REFRESH_CHOICES,
            settings.refresh_minutes,
            |settings, minutes| {
                settings.refresh_minutes = minutes;
            },
        ),
    ));
    content.append(&row(
        "Appearance",
        "System, dark or light theme",
        &segmented(
            &weak,
            &APPEARANCE_CHOICES,
            settings.appearance,
            |settings, appearance| {
                settings.appearance = appearance;
                apply_appearance(appearance);
            },
        ),
    ));

    let placement = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.append(&placement);

    // Filled each time the popover opens, since repositories come and go.
    content.append(&section_title("Repositories"));
    let repos = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let repos_scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .max_content_height(196)
        .propagate_natural_height(true)
        .child(&repos)
        .build();
    content.append(&repos_scroller);

    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    footer.add_css_class("settings-footer");
    let version = label(
        concat!("v", env!("CARGO_PKG_VERSION")),
        &["mono", "version"],
    );
    version.set_hexpand(true);
    footer.append(&version);
    let quit = gtk::Button::builder()
        .label("Quit")
        .action_name("app.quit")
        .build();
    quit.add_css_class("text-link");
    footer.append(&quit);
    content.append(&footer);

    let popover = gtk::Popover::builder()
        .child(&content)
        .has_arrow(false)
        .build();
    popover.add_css_class("settings");
    popover.connect_show(move |_| {
        if let Some(widget) = weak.upgrade() {
            fill_repositories(&widget, &repos);
            fill_placement(&widget, &placement);
        }
    });
    popover
}

fn fill_placement(widget: &Rc<Widget>, container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
    let settings = widget.settings();
    let weak = Rc::downgrade(widget);
    let coordinates = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    coordinates.set_visible(settings.corner == Corner::Custom);
    for (axis, value) in [("X", settings.custom_x), ("Y", settings.custom_y)] {
        coordinates.append(&label(axis, &[]));
        let input = gtk::SpinButton::with_range(f64::from(i32::MIN), f64::from(i32::MAX), 1.0);
        input.set_value(f64::from(value));
        input.set_width_chars(5);
        input.set_tooltip_text(Some("Logical pixels from the main work area's top-left"));
        let weak = weak.clone();
        input.connect_value_changed(move |input| {
            if let Some(widget) = weak.upgrade() {
                widget.update_settings(|settings| {
                    if axis == "X" {
                        settings.custom_x = input.value_as_int();
                    } else {
                        settings.custom_y = input.value_as_int();
                    }
                });
            }
        });
        coordinates.append(&input);
    }
    let choices = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    choices.add_css_class("segmented");
    let mut first: Option<gtk::ToggleButton> = None;
    for (corner, title, icon) in POSITION_CHOICES {
        let content = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        content.append(&image(icon, 14, &[]));
        if corner == Corner::Custom {
            content.append(&label("Custom", &[]));
        }
        let button = gtk::ToggleButton::builder()
            .child(&content)
            .tooltip_text(title)
            .active(corner == settings.corner)
            .build();
        button.update_property(&[gtk::accessible::Property::Label(title)]);
        if let Some(first) = &first {
            button.set_group(Some(first));
        } else {
            first = Some(button.clone());
        }
        let weak = weak.clone();
        let coordinates = coordinates.clone();
        button.connect_toggled(move |button| {
            if button.is_active() {
                coordinates.set_visible(corner == Corner::Custom);
                if let Some(widget) = weak.upgrade() {
                    widget.update_settings(|settings| settings.corner = corner);
                }
            }
        });
        choices.append(&button);
    }
    container.append(&row("Position", "Corner or custom coordinates", &choices));
    container.append(&coordinates);
}

fn fill_repositories(widget: &Rc<Widget>, container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }

    let repos = widget.prefs.borrow().repositories(&widget.prs.borrow());
    if repos.is_empty() {
        let hint = label(
            "Repositories show up here once pull requests load.",
            &["settings-hint"],
        );
        hint.set_margin_start(10);
        hint.set_margin_bottom(6);
        container.append(&hint);
        return;
    }

    let weak = Rc::downgrade(widget);
    for repo in repos {
        let watched = widget.prefs.borrow().is_watched(&repo);
        let toggle = gtk::Switch::builder()
            .active(watched)
            .valign(gtk::Align::Center)
            .build();
        let weak = weak.clone();
        let name = repo.clone();
        toggle.connect_active_notify(move |toggle| {
            if let Some(widget) = weak.upgrade() {
                let on = toggle.is_active();
                widget.update_prefs(None, |prefs| prefs.set_watched(&name, on));
            }
        });

        let name = label(&repo, &["mono", "repo-name"]);
        name.set_hexpand(true);
        name.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 16);
        row.add_css_class("settings-row");
        row.append(&name);
        row.append(&toggle);
        container.append(&row);
    }
}

fn section_title(text: &str) -> gtk::Label {
    label(text, &["settings-title"])
}

fn row(title: &str, subtitle: &str, control: &impl IsA<gtk::Widget>) -> gtk::Box {
    let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
    text.set_hexpand(true);
    text.set_valign(gtk::Align::Center);
    text.append(&label(title, &["settings-label"]));
    text.append(&label(subtitle, &["settings-hint"]));

    let row = gtk::Box::new(gtk::Orientation::Horizontal, 16);
    row.add_css_class("settings-row");
    row.append(&text);
    control.set_valign(gtk::Align::Center);
    row.append(control);
    row
}

fn switch(widget: &Weak<Widget>, active: bool, set: fn(&mut Settings, bool)) -> gtk::Switch {
    let switch = gtk::Switch::builder().active(active).build();
    let widget = widget.clone();
    switch.connect_active_notify(move |switch| {
        if let Some(widget) = widget.upgrade() {
            let on = switch.is_active();
            widget.update_settings(|settings| set(settings, on));
        }
    });
    switch
}

/// A row of linked toggle buttons, one per choice.
fn segmented<T: Copy + PartialEq + 'static>(
    widget: &Weak<Widget>,
    choices: &[(T, &str)],
    current: T,
    set: fn(&mut Settings, T),
) -> gtk::Box {
    let group = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    group.add_css_class("segmented");

    let mut first: Option<gtk::ToggleButton> = None;
    for &(value, title) in choices {
        let button = gtk::ToggleButton::builder()
            .label(title)
            .active(value == current)
            .build();
        if let Some(first) = &first {
            button.set_group(Some(first));
        } else {
            first = Some(button.clone());
        }
        let widget = widget.clone();
        button.connect_toggled(move |button| {
            if button.is_active()
                && let Some(widget) = widget.upgrade()
            {
                widget.update_settings(|settings| set(settings, value));
            }
        });
        group.append(&button);
    }
    group
}
