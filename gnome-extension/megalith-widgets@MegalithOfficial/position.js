export function resolvePosition([corner, x, y], size, areas, primaryIndex = 0) {
    const primary = areas[primaryIndex];
    if (!primary)
        return null;

    let area = primary;
    if (corner === 'custom') {
        x += primary.x;
        y += primary.y;
        let bestOverlap = 0;
        for (const candidate of areas) {
            const width = Math.max(0, Math.min(x + size.width, candidate.x + candidate.width) - Math.max(x, candidate.x));
            const height = Math.max(0, Math.min(y + size.height, candidate.y + candidate.height) - Math.max(y, candidate.y));
            if (width * height > bestOverlap) {
                area = candidate;
                bestOverlap = width * height;
            }
        }
    } else {
        x = corner.endsWith('right') ? area.x + area.width - size.width - 10 : area.x + 10;
        y = corner.startsWith('bottom') ? area.y + area.height - size.height - 10 : area.y + 10;
    }
    return {
        x: Math.min(Math.max(x, area.x), Math.max(area.x, area.x + area.width - size.width)),
        y: Math.min(Math.max(y, area.y), Math.max(area.y, area.y + area.height - size.height)),
    };
}
