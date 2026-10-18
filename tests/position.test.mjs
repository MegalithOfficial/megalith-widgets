import assert from 'node:assert/strict';
import test from 'node:test';
import {resolvePosition} from '../gnome-extension/megalith-widgets@MegalithOfficial/position.js';

const area = {x: 0, y: 32, width: 1440, height: 868};
const size = {width: 760, height: 300};

test('all four corners respect the work area', () => {
    for (const [corner, expected] of [
        ['top-left', {x: 10, y: 42}],
        ['top-right', {x: 670, y: 42}],
        ['bottom-left', {x: 10, y: 590}],
        ['bottom-right', {x: 670, y: 590}],
    ]) {
        assert.deepEqual(resolvePosition([corner, 123, 456], size, [area]), expected);
    }
});

test('custom coordinates are relative to the primary work area', () => {
    assert.deepEqual(resolvePosition(['custom', 120, 80], size, [area]), {x: 120, y: 112});
});

test('custom positions on another monitor are preserved', () => {
    const left = {x: -1440, y: 0, width: 1440, height: 900};
    assert.deepEqual(resolvePosition(['custom', -1000, 80], size, [area, left]), {x: -1000, y: 112});
});

test('disconnected displays cannot leave the widget offscreen', () => {
    assert.deepEqual(resolvePosition(['custom', -1000, 1200], size, [area]), {x: 0, y: 600});
});

test('oversized panels keep their title reachable', () => {
    assert.deepEqual(resolvePosition(['bottom-right', 0, 0], {width: 2000, height: 1000}, [area]), {x: 0, y: 32});
});

test('missing primary display does not place the widget', () => {
    assert.equal(resolvePosition(['top-left', 0, 0], size, []), null);
});
