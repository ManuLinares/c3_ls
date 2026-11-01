module analyzer::core;
import std::io;

struct Location (Printable)
{
	int line;
	int column;
}

fn sz? Location.to_format(Location* self, Formatter* fmt) @dynamic
{
	return fmt.printf("(Line: %d, Column: %d)", self.line + 1, self.column + 1);
}

fn bool Location.eq(self, Location other) @operator(==)
{
	return self.line == other.line && self.column == other.column;
}

struct Range (Printable)
{
	Location start;
	Location end;
}

fn sz? Range.to_format(Range* self, Formatter* fmt) @dynamic
{
	return fmt.printf("start: %s, end: %s", self.start, self.end);
}

fn bool Range.eq(self, Range other) @operator(==)
{
	return self.start == other.start && self.end == other.end;
}

fn bool Range.contains(self, Location loc)
{
	if (loc.line < self.start.line || loc.line > self.end.line)
	{
		return false;
	}

	if (loc.line == self.start.line && loc.column < self.start.column)
	{
		return false;
	}

	if (loc.line == self.end.line && loc.column >= self.end.column)
	{
		return false;
	}

	return true;
}

fn bool Range.contains_range(self, Range other)
{
	bool start_le = (self.start.line < other.start.line) ||
	(self.start.line == other.start.line &&
	self.start.column <= other.start.column);

	bool end_ge = (self.end.line > other.end.line) ||
	(self.end.line == other.end.line &&
	self.end.column >= other.end.column);

	return start_le && end_ge;
}