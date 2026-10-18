//! Right-click menus for rows and for the widget itself.

use super::{Widget, open_uri};
use crate::github::Pr;
use gtk::prelude::*;
use gtk::{gdk, gio, glib, graphene};
use std::rc::{Rc, Weak};

const GROUP: &str = "widget";

/// Registers the `widget.*` actions the menus point at.
pub fn install_actions(widget: &Rc<Widget>) {
    let group = gio::SimpleActionGroup::new();

    let pr_action = |name: &str, run: fn(&Widget, &Pr)| {
        let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
        let weak = Rc::downgrade(widget);
        action.connect_activate(move |_, parameter| {
            let Some(widget) = weak.upgrade() else { return };
            let Some(id) = parameter.and_then(|value| value.get::<String>()) else {
                return;
            };
            let pr = widget.prs.borrow().iter().find(|pr| pr.id == id).cloned();
            if let Some(pr) = pr {
                run(&widget, &pr);
            }
        });
        group.add_action(&action);
    };

    pr_action("open", |_, pr| open_uri(&pr.url));
    pr_action("copy-link", |widget, pr| {
        widget.window.clipboard().set_text(&pr.url)
    });
    pr_action("pin", |widget, pr| {
        widget.update_prefs(None, |prefs| prefs.set_pinned(pr, true))
    });
    pr_action("unpin", |widget, pr| {
        widget.update_prefs(None, |prefs| prefs.set_pinned(pr, false))
    });
    pr_action("ignore", |widget, pr| {
        widget.update_prefs(Some(format!("Ignored “{}”", pr.title)), |prefs| {
            prefs.ignore(pr)
        });
    });
    pr_action("unwatch", |widget, pr| {
        widget.update_prefs(Some(format!("Stopped watching {}", pr.repo)), |prefs| {
            prefs.set_watched(&pr.repo, false);
        });
    });

    let watch = gio::SimpleAction::new("watch", Some(glib::VariantTy::STRING));
    watch.connect_activate(weak_handler(widget, |widget, parameter| {
        if let Some(repo) = parameter.and_then(|value| value.get::<String>()) {
            widget.update_prefs(None, |prefs| prefs.set_watched(&repo, true));
        }
    }));
    group.add_action(&watch);

    let unignore = gio::SimpleAction::new("unignore-all", None);
    unignore.connect_activate(weak_handler(widget, |widget, _| {
        widget.update_prefs(None, |prefs| prefs.unignore_all());
    }));
    group.add_action(&unignore);

    let search = gio::SimpleAction::new("search", None);
    search.connect_activate(weak_handler(widget, |widget, _| widget.open_search()));
    group.add_action(&search);

    let close_search = gio::SimpleAction::new("close-search", None);
    close_search.connect_activate(weak_handler(widget, |widget, _| widget.close_search()));
    group.add_action(&close_search);

    // Ctrl+F opens search from anywhere in the widget.
    let shortcuts = gtk::ShortcutController::new();
    shortcuts.set_scope(gtk::ShortcutScope::Global);
    shortcuts.add_shortcut(gtk::Shortcut::new(
        gtk::ShortcutTrigger::parse_string("<Control>f"),
        Some(gtk::NamedAction::new(&format!("{GROUP}.search"))),
    ));
    widget.window.add_controller(shortcuts);

    let undo = gio::SimpleAction::new("undo", None);
    undo.connect_activate(weak_handler(widget, |widget, _| widget.undo()));
    group.add_action(&undo);

    widget.window.insert_action_group(GROUP, Some(&group));
}

/// Opens the row menu on right-click over a row, and the widget menu anywhere else.
pub fn attach(widget: &Rc<Widget>) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let weak = Rc::downgrade(widget);
    gesture.connect_pressed(move |gesture, _, x, y| {
        let Some(widget) = weak.upgrade() else { return };
        gesture.set_state(gtk::EventSequenceState::Claimed);

        let menu = row_at(&widget, x, y)
            .map(|pr| row_menu(&widget, &pr))
            .unwrap_or_else(|| widget_menu(&widget));
        popup(&widget.card, &menu, x, y);
    });
    widget.card.add_controller(gesture);
}

fn weak_handler(
    widget: &Rc<Widget>,
    run: impl Fn(&Widget, Option<&glib::Variant>) + 'static,
) -> impl Fn(&gio::SimpleAction, Option<&glib::Variant>) + 'static {
    let weak: Weak<Widget> = Rc::downgrade(widget);
    move |_, parameter| {
        if let Some(widget) = weak.upgrade() {
            run(&widget, parameter);
        }
    }
}

/// Finds the PR under a point given in card coordinates.
fn row_at(widget: &Widget, x: f64, y: f64) -> Option<Pr> {
    let point = widget
        .card
        .compute_point(&widget.list, &graphene::Point::new(x as f32, y as f32))?;
    if !widget.list.is_drawable() || !widget.list.contains(point.x() as f64, point.y() as f64) {
        return None;
    }
    let row = widget.list.row_at_y(point.y() as i32)?;
    let rows = widget.rows.borrow();
    let id = &rows.iter().find(|entry| entry.widget == row)?.id;
    widget.prs.borrow().iter().find(|pr| &pr.id == id).cloned()
}

fn row_menu(widget: &Widget, pr: &Pr) -> gio::Menu {
    let item = |label: &str, action: &str| {
        let item = gio::MenuItem::new(Some(label), None);
        item.set_action_and_target_value(
            Some(&format!("{GROUP}.{action}")),
            Some(&pr.id.to_variant()),
        );
        item
    };
    let section = |items: &[gio::MenuItem]| {
        let section = gio::Menu::new();
        for entry in items {
            section.append_item(entry);
        }
        section
    };

    let pinned = widget.prefs.borrow().is_pinned(pr);
    let menu = gio::Menu::new();
    menu.append_section(
        None,
        &section(&[
            item("Open on GitHub", "open"),
            item("Copy Link", "copy-link"),
        ]),
    );
    menu.append_section(
        None,
        &section(&[if pinned {
            item("Unpin", "unpin")
        } else {
            item("Pin to Top", "pin")
        }]),
    );
    menu.append_section(
        None,
        &section(&[
            item("Ignore", "ignore"),
            item(&format!("Stop Watching {}", pr.repo), "unwatch"),
        ]),
    );
    menu
}

fn widget_menu(widget: &Widget) -> gio::Menu {
    let menu = gio::Menu::new();

    let general = gio::Menu::new();
    general.append(Some("Refresh"), Some("app.refresh"));
    general.append(Some("Open Review Queue"), Some("app.open-queue"));
    menu.append_section(None, &general);

    let prefs = widget.prefs.borrow();
    let prs = widget.prs.borrow();
    let restore = gio::Menu::new();
    let ignored = prefs.ignored_count(&prs);
    if ignored > 0 {
        let label = if ignored == 1 {
            "Show 1 Ignored PR".to_owned()
        } else {
            format!("Show {ignored} Ignored PRs")
        };
        restore.append(Some(&label), Some(&format!("{GROUP}.unignore-all")));
    }
    for repo in prefs
        .repositories(&prs)
        .iter()
        .filter(|repo| !prefs.is_watched(repo))
    {
        let item = gio::MenuItem::new(Some(&format!("Watch {repo}")), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.watch")), Some(&repo.to_variant()));
        restore.append_item(&item);
    }
    if restore.n_items() > 0 {
        menu.append_section(None, &restore);
    }

    let quit = gio::Menu::new();
    quit.append(Some("Quit"), Some("app.quit"));
    menu.append_section(None, &quit);
    menu
}

fn popup(parent: &gtk::Box, menu: &gio::Menu, x: f64, y: f64) {
    let popover = gtk::PopoverMenu::from_model(Some(menu));
    popover.add_css_class("context-menu");
    popover.set_has_arrow(false);
    popover.set_halign(gtk::Align::Start);
    popover.set_parent(parent);
    popover.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    popover.connect_closed(|popover| {
        // Unparenting inside the signal would dispose it mid-emission.
        let popover = popover.clone();
        glib::idle_add_local_once(move || popover.unparent());
    });
    popover.popup();
}
