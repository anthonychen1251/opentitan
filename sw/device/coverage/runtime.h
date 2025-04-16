#ifndef runtime_h_INCLUDED
#define runtime_h_INCLUDED

void coverage_init(void);
void coverage_report(void);

#define COVERAGE_REPORT coverage_report

#endif  // runtime_h_INCLUDED
