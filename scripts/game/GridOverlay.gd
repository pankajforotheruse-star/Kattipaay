# GridOverlay.gd — Draws a debug grid on the game world
# Lightweight visual reference; removed or disabled in production.

class_name GridOverlay
extends Node2D

@export var grid_size: int = 100
@export var grid_color: Color = Color(0.2, 0.25, 0.3, 0.5)
@export var grid_extent: int = 1000  # half-size of the grid in pixels

func _draw() -> void:
    # Background fill
    draw_rect(Rect2(-grid_extent, -grid_extent, grid_extent * 2, grid_extent * 2), Color(0.1, 0.12, 0.18, 1))

    var start_x := -grid_extent
    var end_x := grid_extent
    var start_y := -grid_extent
    var end_y := grid_extent

    # Vertical lines
    var x := start_x
    while x <= end_x:
        draw_line(Vector2(x, start_y), Vector2(x, end_y), grid_color, 1.0)
        x += grid_size

    # Horizontal lines
    var y := start_y
    while y <= end_y:
        draw_line(Vector2(start_x, y), Vector2(end_x, y), grid_color, 1.0)
        y += grid_size

    # Draw origin crosshair
    draw_line(Vector2(-10, 0), Vector2(10, 0), Color.WHITE, 2.0)
    draw_line(Vector2(0, -10), Vector2(0, 10), Color.WHITE, 2.0)
