
utils around json/zon in zig. Especially converting to zon as it is direct and very convenient to use zon at comptime in zig, a little less for json.

- convert json to zon
- convert zon to json
- TODO mayme json/zon to binary encoded and backward
- TODO bson, cbor , protobuf, ubjson ...??
- TODO merkle hash of data only to compare content
- TODO json comptime parsing of []u8 checks and implement if not working (only allocate stack so dummy not solid allocator is fine here).
