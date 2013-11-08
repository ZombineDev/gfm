module gfm.net.cbor;

import std.range,
       std.bigint,
       std.conv,
       std.utf,
       std.array,
       std.exception,
       std.numeric,
       std.bigint;


/*
  CBOR: Concise Binary Object Representation.
  Implementation of RFC 7049.

  References: $(LINK http://tools.ietf.org/rfc/rfc7049.txt)
  Heavily inspired by std.json by Jeremie Pelletier.

 */

/// Possible type of a CBORValue. Does not map 1:1 to CBOR major types.
enum CBORType
{
    STRING,      /// an UTF-8 encoded string
    BYTE_STRING, /// a string of bytes
    INTEGER,     /// a 64-bits signed integer
    UINTEGER,    /// a 64-bits unsigned integer
    BIGINT,      /// an integer that doesn't fit in either
    FLOATING,    /// a floating-point value
    ARRAY,       /// an array of CBOR values
    MAP,         /// a map CBOR value => CBOR value
    SIMPLE       /// null, undefined, true, false, break, and future values
}

/// CBOR "simple" values
enum : ubyte
{
    CBOR_FALSE = 20,
    CBOR_TRUE  = 21,
    CBOR_NULL  = 22,
    CBOR_UNDEF = 23
}

/// CBOR tags are prefixes that add a semantic meaning + required type to a value
/// Currently emitted (bignums) but not parsed.
enum CBORTag
{
    DATE_TIME              = 0,
    EPOCH_DATE_TIME        = 1,
    POSITIVE_BIGNUM        = 2,
    NEGATIVE_BIGNUM        = 3,
    DECIMAL_FRACTION       = 4,
    BIG_FLOAT              = 5,
    ENCODED_CBOR_DATA_ITEM = 24,
    URI                    = 32,
    BASE64_URI             = 33,
    BASE64                 = 34,
    REGEXP                 = 35,
    MIME_MESSAGE           = 35,
    SELF_DESCRIBE_CBOR     = 55799
}

/**
 
    Holds a single CBOR value.

 */
struct CBORValue
{
    union Store
    {
        ubyte          simpleID;
        string         str;
        ubyte[]        byteStr;
        long           integer;
        ulong          uinteger;
        BigInt         bigint;
        double         floating;
        CBORValue[]    array;
        CBORValue[2][] map; // implemented as an array of (CBOR value, CBOR value) pairs
    }

    CBORType type;
    Store store; 

    this(T)(T arg)
    {
        this = arg;
    }

    /// Create an undefined CBOR value.
    static CBORValue simpleValue(ubyte which)
    {
        CBORValue result;
        result.type = CBORType.SIMPLE;
        result.store.simpleID = which;
        return result;
    }

    void opAssign(T)(T arg)
    {
        static if(is(T : typeof(null)))
        {
            type = CBORType.SIMPLE;
            store.simpleID = CBOR_NULL;
        }
        else static if(is(T : string))
        {
            type = CBORType.STRING;
            store.str = arg;
        }
        else static if(is(T : ubyte[]))
        {
            type = CBORType.BYTE_STRING;
            store.byteStr = arg;
        }
        else static if(is(T : ulong) && isUnsigned!T)
        {
            type = CBORType.UINTEGER;
            store.uinteger = arg;
        }
        else static if(is(T : long))
        {
            type = CBORType.INTEGER;
            store.integer = arg;
        }
        else static if(isFloatingPoint!T)
        {
            type = CBORType.FLOAT;
            store.floating = arg;
        }
        else static if(is(T : bool))
        {
            type = CBORType.SIMPLE;
            store.simpleID = arg ? CBOR_TRUE : CBOR_FALSE;
        }
        else static if(is(T : CBORValue[2][]))
        {
            type = CBORType.MAP;
            store.arg = arg;

            // TODO handle AA
        }
        else static if(isArray!T)
        {
            type = CBORType.ARRAY;
            static if(is(ElementEncodingType!T : CBORValue))
            {
                store.array = arg;
            }
            else
            {
                CBORValue[] new_arg = new CBORValue[arg.length];
                foreach(i, e; arg)
                    new_arg[i] = CBORValue(e);
                store.array = new_arg;
            }
        }       
        else static if(is(T : CBORValue))
        {
            type = arg.type;
            store = arg.store;
        }
        else
        {
            static assert(false, text(`unable to convert type "`, T.stringof, `" to CBORValue`));
        }
    }

    @property bool isNull() pure nothrow const
    {
        return type == CBORType.SIMPLE && store.simpleID == CBOR_NULL;
    }

    @property bool isUndefined() pure nothrow const
    {
        return type == CBORType.SIMPLE && store.simpleID == CBOR_UNDEF;
    }

    /// Typesafe way of accessing $(D store.boolean).
    /// Throws $(D CBORException) if $(D type) is not a bool.
    @property bool boolean() inout
    {
        enforceEx!CBORException(type == CBORType.SIMPLE, "CBORValue is not a bool");
        if (store.simpleID == CBOR_TRUE)
            return true;
        else if (store.simpleID == CBOR_FALSE)
            return false;
        else 
            throw new CBORException("CBORValue is not a bool");
    }

    /// Typesafe way of accessing $(D store.str).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.STRING).
    @property ref inout(string) str() inout
    {
        enforceEx!CBORException(type == CBORType.STRING, "CBORValue is not a string");
        return store.str;
    }

    /// Typesafe way of accessing $(D store.byteStr).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.BYTE_STRING).
    @property ref inout(ubyte[]) byteStr() inout
    {
        enforceEx!CBORException(type == CBORType.BYTE_STRING, "CBORValue is not a byte string");
        return store.byteStr;
    }

    /// Typesafe way of accessing $(D store.integer).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.INTEGER).
    @property ref inout(long) integer() inout
    {
        enforceEx!CBORException(type == CBORType.INTEGER, "CBORValue is not an integer");
        return store.integer;
    }

    /// Typesafe way of accessing $(D store.uinteger).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.UINTEGER).
    @property ref inout(ulong) uinteger() inout
    {
        enforceEx!CBORException(type == CBORType.UINTEGER, "CBORValue is not an unsigned integer");
        return store.uinteger;
    }

    /// Typesafe way of accessing $(D store.bigint).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.BIGINT).
    @property ref inout(BigInt) bigint() inout
    {
        enforceEx!CBORException(type == CBORType.BIGINT, "CBORValue is not a big integer");
        return store.bigint;
    }

    /// Typesafe way of accessing $(D store.floating).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.FLOATING).
    @property ref inout(double) floating() inout
    {
        enforceEx!CBORException(type == CBORType.FLOATING, "CBORValue is not a floating point");
        return store.floating;
    }

    /// Typesafe way of accessing $(D store.map).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.MAP).
    @property ref inout(CBORValue[2][]) map() inout
    {
        enforceEx!CBORException(type == CBORType.MAP, "CBORValue is not an object");
        return store.map;
    }

    /// Typesafe way of accessing $(D store.array).
    /// Throws $(D CBORException) if $(D type) is not $(D CBORType.ARRAY).
    @property ref inout(CBORValue[]) array() inout
    {
        enforceEx!CBORException(type == CBORType.ARRAY, "CBORValue is not an array");
        return store.array;
    }
}

/// Exception thrown on CBOR errors
class CBORException : Exception
{
    this(string msg)
    {
        super(msg);
    }

    this(string msg, string file, size_t line)
    {
        super(msg, file, line);
    }
}

/// Decode a single CBOR object from an input range.
CBORValue decodeCBOR(R)(R input) if (isInputRange(R))
{
    CBORValue result; 

    ubyte firstByte = popByte();
    MajorType majorType = firstByte() >> 5;
    ubyte rem = firstByte & 31;

    final switch(majorType)
    {
        case CBORMajorType.POSITIVE_INTEGER:
            return CBORValue(readBigEndianInt(input, rem));

        case CBORMajorType.NEGATIVE_INTEGER:
        {
            ulong ui = readBigEndianInt(input, rem);
            long neg = -1 - ui;
            if (neg < 0)
                return CBORValue(neg); // does fit in a longs
            else
                return CBORValue(-BigInt(ui) - 1); // doesn't fit in a a long
        }

        case CBORMajorType.BYTE_STRING:
        {
            ulong ui = readBigEndianInt(input, rem);
            ubyte[] bytes = new ubyte[ui];
            for(uint i = 0; i < ui; ++i)
                bytes[i] = input.popByte();
            return CBORValue(assumeUnique(bytes));
        }

        case CBORMajorType.UTF8_STRING:
        {
            ulong ui = readBigEndianInt(input, rem);
            char[] sbytes = new char[ui];
            for(uint i = 0; i < ui; ++i)
                sbytes[i] = input.popByte();

            try
            {
                validate(sbytes);
            }
            catch(Exception e)
            {
                // ill-formed unicode
                throw CBORException("Invalid UTF-8 string");
            }
            return CBORValue(assumeUnique(sbytes));
        }

        case CBORMajorType.ARRAY:
        {
            ulong ui = readBigEndianInt(input, rem);
            CBORValue[] items = new CBORValue[ui];

            foreach(ref item; items)
                item = decodeCBOR(input);
            
            return CBORValue(assumeUnique(items));
        }

        case CBORMajorType.MAP:
        {
            ulong ui = readBigEndianInt(input, rem);
            CBORValue[2][] items = new CBORValue[2][ui];

            for(ulong i = 0; i < ui; ++i)
            {
                items[0] = decodeCBOR(input);
                items[1] = decodeCBOR(input);
            }
            
            return CBORValue(assumeUnique(items));
        }

        case CBORMajorType.SEMANTIC_TAG:
        {
            // skip tag value
            readBigEndianInt(input, rem);

            // TODO: do not ignore tags
            return decodeCBOR(input);
        }

        case CBORMajorType.TYPE_7:
        {
            if (rem == 25) // half-float
            {
                union
                {
                    CustomFloat!16 f;
                    ushort i;
                } u;
                u.i = cast(ushort)readBigEndianIntN(input, 2);
                return CBORValue(cast(double)i.f);
            }
            else if (rem == 26) // float
            {
                union
                {
                    float f;
                    uint i;
                } u;
                u.i = cast(uint)readBigEndianIntN(input, 2);
                return CBORValue(cast(double)i.f);
            }
            else if (rem == 27) // double
            {
                union
                {
                    double f;
                    ulong i;
                } u;
                u.i = readBigEndianIntN(input, 2);
                return CBORValue(cast(real)i.f);
            }
            else
            {
                ubyte simpleID = rem;
                if (rem == 24)
                {
                    simpleID =  input.popByte();
                }

                // unknown simple values are kept as is
                return CBORValue.simpleValue(simpleID);
            }
        }
    }
    
    return result;
}

/// Encode a single CBOR object to an array of bytes.
/// Only ever output so-called Canonical CBOR.
ubyte[] encodeCBOR(CBORValue value)
{
    auto app = std.array.appender!(ubyte[]);
    encodeCBOR(app, value);
    return app.data();
}

/// Encode a single CBOR object in a range.
/// Only ever output so-called Canonical CBOR.
void encodeCBOR(R)(R output, CBORValue value) if (isOutputRange!(R, ubyte))
{
    final switch(value.type)
    {
        case CBORType.STRING:
        {
            writeMajorTypeAndBigEndianInt(output, CBORMajorType.UTF8_STRING, value.store.str.length);
            foreach(char b; value.store.str)
                output.put(b);
            break;
        }

        case CBORType.BYTE_STRING: 
        {            
            writeMajorTypeAndBigEndianInt(output, CBORMajorType.BYTE_STRING, value.store.byteStr.length);
            foreach(ubyte b; value.store.byteStr)
                output.put(b);
            break;
        }

        case CBORType.INTEGER:
        {
            long x = value.store.integer;
            if (x >= 0)
                writeMajorTypeAndBigEndianInt(output, CBORMajorType.POSITIVE_INTEGER, x);
            else
                writeMajorTypeAndBigEndianInt(output, CBORMajorType.NEGATIVE_INTEGER, -x - 1); // always fit
        }

        case CBORType.UINTEGER:
        {
            writeMajorTypeAndBigEndianInt(output, CBORMajorType.POSITIVE_INTEGER, value.store.uinteger);
            break;
        }

        case CBORType.BIGINT:
        {
            BigInt N = value.store.bigint;
            if (0 <= N && N <= 4294967295)
            {
                // fit in a positive integer
                writeMajorTypeAndBigEndianInt(output, CBORMajorType.POSITIVE_INTEGER, N.toLong());
            }
            else if (-4294967296 <= N && N < 0)
            {
                // fit in a negative integer
                writeMajorTypeAndBigEndianInt(output, CBORMajorType.NEGATIVE_INTEGER, (-N-1).toLong());
            }
            else
            {
                // doesn't fit in integer major types
                // lack of access to byte data => using a hex string for now
                if (N >= 0)
                    output.putTag(CBORTag.POSITIVE_BIGNUM);
                else
                {
                    output.putTag(CBORTag.NEGATIVE_BIGNUM);
                    N = -N - 1;
                }

                ubyte[] bytes = bigintBytes(N);
                
                writeMajorTypeAndBigEndianInt(output, CBORMajorType.BYTE_STRING, bytes.length);
                foreach(ubyte b; bytes)
                    output.put(b);
            }
            break;
        }

        case CBORType.FLOATING:
            assert(false); // TODO
            break;

        case CBORType.ARRAY:
        {
            size_t l = value.store.array.length;
            writeMajorTypeAndBigEndianInt(output, CBORMajorType.ARRAY, l);
            for(size_t i = 0; i < l; ++i)
                encodeCBOR(output, value.store.array[i]);
            break;
        }
        case CBORType.MAP:
        {
            size_t l = value.store.map.length;
            writeMajorTypeAndBigEndianInt(output, CBORMajorType.MAP, l);
            for(size_t i = 0; i < l; ++i)
            {
                encodeCBOR(output, value.store.map[i][0]);
                encodeCBOR(output, value.store.map[i][1]);
            }
            break;
        }

        case CBORType.SIMPLE: 
            assert(false); // TODO
            break;
    }
    assert(false);
}

private 
{
    enum CBORMajorType
    {
        POSITIVE_INTEGER = 0,
        NEGATIVE_INTEGER = 1,
        BYTE_STRING      = 2,
        UTF8_STRING      = 3,
        ARRAY            = 4,
        MAP              = 5,
        SEMANTIC_TAG     = 6,
        TYPE_7           = 7
    }

    ubyte peekByte(R)(R input) if (isInputRange(R))
    {
        if (input.empty)
            throw CBORException("Expected a byte, found end of input");
        return next;
    }

    ubyte popByte(R)(R input) if (isInputRange(R))
    {
        ubyte b = peekByte();
        input.popFront();
        return b;
    }

    ulong readBigEndianInt(R)(R input, ubyte rem) if (isInputRange(R))
    {
        if (rem <= 23)
            return rem;

        int numBytes = 0;

        if (rem >= 24 && rem <= 27)
        {
            numBytes = 1 << (rem - 24);
            return readBigEndianIntN(input, numBytes);
        }
        else
            throw CBORException(text("Unexpected 5-bit value: ", rem));
    }

    ulong readBigEndianIntN(R)(R input, int numBytes) if (isInputRange(R))
    {
        ulong result = 0;
        for (int i = 0; i < numBytes; ++i)
            result = (result << 8) | input.popByte();
        return result;
    }

    void writeMajorTypeAndBigEndianInt(R)(R output, ubyte majorType, ulong n) if (isOutputRange!(R, ubyte))
    {
        int nAddBytes;
        ubyte firstB = (majorType << 5) & 255;
        if (0 <= n && n <= 23)
        {
            // encode with major type
            ubyte b = firstB | (n & 255);
            output.put(b);
            nAddBytes = 0;
        }
        else if (24 <= n && n <= 255)
        {
            ubyte b = firstB | 24;
            output.put(b);
            nAddBytes = 1;
        }
        else if (256 <= n && n <= 65535)
        {
            ubyte b = firstB | 25;
            output.put(b);
            nAddBytes = 2;
        }
        else if (65536 <= n && n <= 4294967295)
        {
            ubyte b = firstB | 26;
            output.put(b);
            nAddBytes = 4;
        }
        else 
        {
            ubyte b = firstB | 27;
            output.put(b);
            nAddBytes = 8;
        }

        for (int i = 0; i < nAddBytes; ++i)
        {
            ubyte b = (n >> ((nAddBytes - 1 - i) * 8)) & 255;
            output.put(b);
        }
    }

    void putTag(R)(R output, CBORTag tag) if (isOutputRange!(R, ubyte))
    {
        output.writeMajorTypeAndBigEndianInt(CBORMajorType.SEMANTIC_TAG, tag);
    }

    // Convert BigInt to bytes, much too involved.
    ubyte[] bigintBytes(BigInt n)
    {
        assert(n >= 0);
        string s = n.toHex();
        if (s.length % 2 != 0)
            assert(false);

        int hexCharToInt(char c)
        {
            if (c >= '0' && c <= '9')
                return c - '0';
            else if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                return c - 'A' + 10;
            else
                assert(false);
        }

        size_t len = s.length / 2;
        ubyte[] bytes = new ubyte[len];
        for (size_t i = 0; i < len; ++i)
        {
            bytes[i] = cast(ubyte)(hexCharToInt(s[i * 2]) * 16 + hexCharToInt(s[i * 2 + 1]));
        }           
        return bytes;
    }
}