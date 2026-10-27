export class SSEParser {
  buffer = "";
  data = [];

  feed(text, final = false) {
    this.buffer += text;
    const events = [];
    while (true) {
      const index = this.buffer.search(/[\r\n]/);
      if (index < 0) break;
      const isCR = this.buffer[index] === "\r";
      if (isCR && index === this.buffer.length - 1 && !final) break;
      const size = isCR && this.buffer[index + 1] === "\n" ? 2 : 1;
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + size);
      if (line === "") {
        if (this.data.length) events.push(this.data.join("\n"));
        this.data = [];
      } else if (line.startsWith("data:")) {
        const value = line.slice(5);
        this.data.push(value.startsWith(" ") ? value.slice(1) : value);
      }
    }
    return events;
  }
}
