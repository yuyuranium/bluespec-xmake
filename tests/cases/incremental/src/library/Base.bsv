package Base;

import Leaf::*;
import Other::*;

function Integer baseValue();
    return leafValue() + otherValue();
endfunction

endpackage
