// Pasted into each fluid pass (impellerc has no include of our own files): numbers
// kept in an eight-bit picture with more than eight bits.
//
// Alpha has to stay 1 — a Flutter image is premultiplied, so a value in alpha
// would scale the others — which leaves three bytes. Two numbers go in as twelve
// bits each (a velocity's x and y); one number as twenty-four (the pressure).
