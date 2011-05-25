//Written in the D programming language
/**
 * Fast Regular expressions for D
 *
 * License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
 *
 * Authors: Dmitry Olshansky
 *
 */
module regex;

import std.stdio;
import std.algorithm, std.range, std.conv, std.exception, std.ctype, std.format, std.typecons;

enum:uint {
    IRchar              =      0,
    IRstring            =  1<<24,
    IRany               =  2<<24,
    IRcharset           =  3<<24,
    IRalter             =  4<<24,
    IRnm                =  5<<24,
    IRstar              =  6<<24,
    IRcross             =  7<<24,
    IRquest             =  8<<24,
    IRnmq               =  9<<24,
    IRstarq             = 10<<24,
    IRcrossq            = 11<<24,
    IRconcat            = 12<<24,
    IRdigit             = 13<<24,
    IRnotdigit          = 14<<24,
    IRspace             = 15<<24,
    IRnotspace          = 16<<24,
        
    IRgroup             = 32<<24,
    IRlookahead         = 33<<24,
    IRneglookahead      = 34<<24,
    IRlookbehind        = 35<<24,
    IRneglookbehind     = 36<<24,
    //TODO: ...
    IRlambda            = 128<<24
};


struct RecursiveParser(R)
if (isForwardRange!R && is(ElementType!R : dchar))
{
    enum infinite = ~0u;
    dchar _current;
    bool empty;
    R pat, origin;
    uint[] ir;
    uint[] index; //for numbered captures
    struct NamedGroup
    { 
        string name; 
        uint group;
    }
    NamedGroup[] dict; //for named ones
    uint nsub = 0, nesting = 0, top = 0;
    this(R pattern)
    {
        origin = pat = pattern;
        ir.reserve(pat.length);
        next();
        parseRegex();
    }
    void skipSpace()
    {
        while(isspace(current) && next()){ }
    }
    @property dchar current(){ return _current; }
    void put(uint code){  ir ~= code; }
    bool next()
    {
        if(pat.empty)
        {
            empty =  true;
            return false;
        }
        _current = pat.front;
        pat.popFront();
        return true;
    }
    uint parseNumber()
    {
        uint r=0;
        while(isdigit(current))
        {
            if(r >= (uint.max/10)) 
                error("Overflow in repetition count");
            r = 10*r + cast(uint)(current-'0'); 
            next();
        }
        return r;
    }

    void parseRegex()
    {
        while(!empty)
            switch(current)
            {
                case '|':
                    nsub = nesting;
                    next();
                    //alternation
                    parseConcat();
                    put(IRalter);
                    //TODO: account empty alternation  (a|) -> (a|*lambda*)
                    break;
                case ')':
                    return;
                default:
                    parseConcat();
            }
    }
    void parseConcat()
    {
        parseRepetition();
        while(!empty)
            switch(current)
            {
            case '|': case ')':
                return;
            default:
                parseRepetition();
                put(IRconcat);
            }
    }
    void parseRepetition()
    {
        parseAtom();
        if(empty)
            return;
        uint min, max;
        switch(current)
        {
        case '*':
            if(next())
                if(current == '?')
                {
                    put(IRstarq); 
                    next();
                }
            else
                put(IRstar);
            break;
        case '?':
            next();
            put(IRquest);
            break;
        case '+':
            if(next())
                if(current == '?')
                {
                    put(IRcrossq); 
                    next();
                }
            else
                put(IRcross);
            break;
        case '{':
            if(!next())
                error("Unexpected end of regex pattern");
            if(!isdigit(current))
                error("First number required in repetition"); 
            min = parseNumber();    
            skipSpace();
            if(current == '}')
                max = min;
            else if(current == ',')
            {
                next();
                if(isdigit(current))
                    max = parseNumber();
                else if(current == '}')
                    max = infinite;
                else
                    error("Unexpected symbol in regex pattern"); 
                skipSpace();
                if(current != '}')
                    error("Unmatched '{' in regex pattern");
            }
            else
                error("Unexpected symbol in regex pattern");
            next();       
            if(current == '?')
            {
                put(IRnmq);
                next();
            }
            else
                put(IRnm);
            put(min);
            put(max);
                    
            break;
        default:
            break;
        }
    }
    void parseAtom()
    {
        if(empty)
            return;
        switch(current)
        {
        case '*', '?', '+', '|', '{', '}':
            error("'*', '+', '?', '{', '}' not allowed in atom");
            break;
        case '.':
            put(IRany);
            next();
            break;
        case '(':
            R save = pat;
            next();
            uint op = 0, nglob;
            if(current == '?')
            {
                next();
                switch(current)
                {
                case '=':
                    op = IRlookahead;
                    next();
                    break;
                case '!':
                    op = IRneglookahead;
                    next();
                    break;
                case 'P':
                    next();
                    if(current != '<')
                        error("Expected '<' in named group");
                    string name;
                    while(next() && isalpha(current))
                    {
                        name ~= current;
                    }
                    if(current != '>')
                        error("Expected '>' closing named group");
                    next();
                    auto old = nsub++;
                    nesting++;
                    top = max(nsub,top);
                    nglob = cast(uint)index.length;
                    index ~= old;
                    auto t = NamedGroup(name,old);
                    auto d = assumeSorted!"a.name < b.name"(dict);
                    auto ind = d.lowerBound(t).length;
                    insertInPlace(dict, ind, t);
                    op = IRgroup | old;
                    break;
                case '<':
                    next();
                    if(current == '=')
                        op = IRlookbehind;
                    else if(current == '!')
                        op = IRneglookbehind;
                    else
                        error("'!' or '=' expected after '<'");
                    next();
                    break;
                default:
                    //nothing
                }
            }
            else
            {
                auto old = nsub++;
                nesting++;
                top = max(nsub,top);
                nglob = cast(uint)index.length;
                index ~= old;
                op = IRgroup | old;
            }
            parseRegex();
            if(current != ')')
            {
                pat = save;
                error("Unmatched '(' in regex pattern");
            }
            assert(nsub < (1<<24));
            if((op & 0xff00_0000) == IRgroup)
            {
                assert(nesting);
                --nesting;
                put(op);
                put(nglob);
            }
            else if(op)
                put(op);
            next();
            break;
        case '[':
            //range
            assert(0);
            break;
        case '\\':
            //escape
            //parseEscape();
            assert(0);
            break;
        case ')':
            break;
        default:
            put(current);
            next();
        }
    }
    void error(string msg)
    {
        auto app = appender!string;
        formattedWrite(app,"%s\nPattern with error: `%s <--HERE-- %s`",
                       msg, origin[0..$-pat.length], pat);
        throw new RegexException(app.data);
    }
    void printPostfix()
    {
        for(size_t i=0;i<ir.length;i++)
        {
            switch(ir[i] & 0xff00_0000)
            {
            case IRchar:
                write(cast(dchar)ir[i]);
                break;
            case IRany:
                write("(.)");
                break;
            case IRconcat:
                write('.');
                break;
            case IRquest:
                write('?');
                break;
            case IRstar:
                write('*');
                break;
            case IRstarq:
                write("*?");
                break;
            case IRcross:
                write('+');
                break;
            case IRcrossq:
                write("+?");
                break;
            case IRnm:
                writef("{%u,%u}",ir[i+1],ir[i+2]);
                i += 2;//2 extra words
                break;
            case IRnmq:
                writef("{%u,%u}?",ir[i+1],ir[i+2]);
                i += 2;//ditto
                break;
            case IRalter:
                write('|');
                break;
            case IRgroup:
                uint n = ir[i] & 0x00ff_ffff;
                //auto ng = find!((x){ return x.group == n; })(dict); // Ouch: '!vthis->csym' on line 713 in file 'glue.c'
                string name;
                foreach(v;dict)
                    if(v.group == n)
                    {
                        name = "<"~v.name~">";
                        break;   
                    }
                writef("(%s%u->%u)", name, n, ir[i+1]);
                i++;//1 extra word
                break;
            case IRlookahead:
                uint n = ir[i] & 0x00ff_ffff;
                writef("(?=%u)",  n);
                break;
            case IRneglookahead: 
                uint n = ir[i] & 0x00ff_ffff;
                writef("(?!%u)",  n);
                break;
            case IRlookbehind:
                uint n = ir[i] & 0x00ff_ffff;
                writef("(?<=%u)",  n);
                break;
            case IRneglookbehind:
                uint n = ir[i] & 0x00ff_ffff;
                writef("(?<!%u)",  n);
                break;
            }
        }
    }
}

//Actual instructions for VM 
enum InstType:uint {
    Banychar,
    Bchar,
    Bnotchar,
    Brange,
    Bnotrange,
    Bstring,
    Bsplit,
    Bsave
};

struct GenericInst{
    InstType type;
    union{
        dchar ch;
        uint nsave;
        struct{
            dchar low,hi;
        }
        struct{
            uint x,y;
        }
    }
}


struct Inst(InstType type){
    GenericInst inst;
    enum length = instSize!type;
    alias inst this;
}


auto _instSize(InstType type){
    switch(type){
        case InstType.Banychar:
            return InstType.sizeof;
        case InstType.Bchar: case InstType.Bnotchar:
            return InstType.sizeof+dchar.sizeof;
        case InstType.Brange: case InstType.Bnotrange:
            return InstType.sizeof+dchar.sizeof+dchar.sizeof;
        case InstType.Bsplit:
            return InstType.sizeof+uint.sizeof+uint.sizeof;
    }
}

template instSize(InstType t){
    enum opcodeSize = _instSize(t);
}


class RegexException : Exception
{
    this(string msg)
    {
        super(msg);
    }
}