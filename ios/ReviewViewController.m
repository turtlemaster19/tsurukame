//
//  ReviewViewController.m
//  Wordlist
//
//  Created by David Sansome on 29/7/17.
//  Copyright © 2017 David Sansome. All rights reserved.
//

#import "AnswerChecker.h"
#import "LanguageSpecificTextField.h"
#import "ReviewViewController.h"
#import "proto/Wanikani+Convenience.h"

static const int kActiveQueueSize = 10;

static NSArray<id> *kRadicalGradient;
static NSArray<id> *kKanjiGradient;
static NSArray<id> *kVocabularyGradient;
static NSArray<id> *kReadingGradient;
static NSArray<id> *kMeaningGradient;
static UIColor *kReadingTextColor;
static UIColor *kMeaningTextColor;

static void AddShadowToView(UIView *view) {
  view.layer.shadowColor = [UIColor blackColor].CGColor;
  view.layer.shadowOffset = CGSizeMake(1, 1);
  view.layer.shadowOpacity = 0.6;
  view.layer.shadowRadius = 1.5;
  view.clipsToBounds = NO;
}

@interface ReviewViewController () <UITextFieldDelegate>

@property (weak, nonatomic) IBOutlet UIView *questionBackground;
@property (weak, nonatomic) IBOutlet UIView *promptBackground;
@property (weak, nonatomic) IBOutlet UILabel *questionLabel;
@property (weak, nonatomic) IBOutlet UILabel *promptLabel;
@property (weak, nonatomic) IBOutlet LanguageSpecificTextField *answerField;
@property (weak, nonatomic) IBOutlet UIButton *submitButton;
@property (weak, nonatomic) IBOutlet UILabel *correctAnswerLabel;
@property (weak, nonatomic) IBOutlet UIProgressView *progressBar;

@property (weak, nonatomic) IBOutlet UILabel *successRateLabel;
@property (weak, nonatomic) IBOutlet UILabel *doneLabel;
@property (weak, nonatomic) IBOutlet UILabel *queueLabel;
@property (weak, nonatomic) IBOutlet UIImageView *successRateIcon;
@property (weak, nonatomic) IBOutlet UIImageView *doneIcon;
@property (weak, nonatomic) IBOutlet UIImageView *queueIcon;

@property (nonatomic) CAGradientLayer *questionGradient;
@property (nonatomic) CAGradientLayer *promptGradient;

@property (nonatomic) DataLoader *dataLoader;
@property (nonatomic) NSMutableArray<ReviewItem *> *activeQueue;
@property (nonatomic) NSMutableArray<ReviewItem *> *reviewQueue;

@property (nonatomic, readonly) int activeTaskIndex;  // An index into activeQueue;
@property (nonatomic, readonly) WKTaskType activeTaskType;
@property (nonatomic, readonly) ReviewItem *activeTask;
@property (nonatomic, readonly) WKSubject *activeSubject;

@property (nonatomic) int reviewsCompleted;
@property (nonatomic) int tasksAnsweredCorrectly;
@property (nonatomic) int tasksAnswered;

@end

@implementation ReviewViewController

#pragma mark - Constructors

- (instancetype)initWithItems:(NSArray<ReviewItem *> *)items
                   dataLoader:(DataLoader *)dataLoader {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    kRadicalGradient = @[(id)[UIColor colorWithRed:0.000f green:0.667f blue:1.000f alpha:1.0f].CGColor,
                         (id)[UIColor colorWithRed:0.000f green:0.576f blue:0.867f alpha:1.0f].CGColor];
    kKanjiGradient = @[(id)[UIColor colorWithRed:1.000f green:0.000f blue:0.667f alpha:1.0f].CGColor,
                       (id)[UIColor colorWithRed:0.867f green:0.000f blue:0.576f alpha:1.0f].CGColor];
    kVocabularyGradient = @[(id)[UIColor colorWithRed:0.667f green:0.000f blue:1.000f alpha:1.0f].CGColor,
                            (id)[UIColor colorWithRed:0.576f green:0.000f blue:0.867f alpha:1.0f].CGColor];
    kReadingGradient = @[(id)[UIColor colorWithRed:0.235f green:0.235f blue:0.235f alpha:1.0f].CGColor,
                         (id)[UIColor colorWithRed:0.102f green:0.102f blue:0.102f alpha:1.0f].CGColor];
    kMeaningGradient = @[(id)[UIColor colorWithRed:0.933f green:0.933f blue:0.933f alpha:1.0f].CGColor,
                         (id)[UIColor colorWithRed:0.882f green:0.882f blue:0.882f alpha:1.0f].CGColor];
    kReadingTextColor = [UIColor whiteColor];
    kMeaningTextColor = [UIColor colorWithRed:0.333f green:0.333f blue:0.333f alpha:1.0f];
  });
  
  if (self = [super initWithNibName:nil bundle:nil]) {
    NSLog(@"Starting review with %lu items", (unsigned long)items.count);
    _dataLoader = dataLoader;
    _reviewQueue = [NSMutableArray arrayWithArray:items];
    _activeQueue = [NSMutableArray array];
    [self refillActiveQueue];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  AddShadowToView(self.successRateIcon);
  AddShadowToView(self.successRateLabel);
  AddShadowToView(self.doneIcon);
  AddShadowToView(self.doneLabel);
  AddShadowToView(self.queueIcon);
  AddShadowToView(self.queueLabel);
  
  _questionGradient = [CAGradientLayer layer];
  [_questionBackground.layer addSublayer:_questionGradient];
  _promptGradient = [CAGradientLayer layer];
  [_promptBackground.layer addSublayer:_promptGradient];
  
  self.answerField.delegate = self;
}

- (void) viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  _questionGradient.frame = _questionBackground.bounds;
  _promptGradient.frame = _promptBackground.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
  [self randomTask];
  [super viewWillAppear:animated];
  [self.answerField becomeFirstResponder];
}

- (IBAction)backButtonPressed:(id)sender {
  UIAlertController *c =
      [UIAlertController alertControllerWithTitle:@"End review session?"
                                          message:@"You'll lose progress on any half-answered reviews"
                                   preferredStyle:UIAlertControllerStyleAlert];
  [c addAction:[UIAlertAction actionWithTitle:@"End review session"
                                        style:UIAlertActionStyleDestructive
                                      handler:^(UIAlertAction * _Nonnull action) {
                                          [self.navigationController popViewControllerAnimated:YES];
                                        }]];
  [c addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                        style:UIAlertActionStyleCancel
                                      handler:nil]];
  [c addAction:[UIAlertAction actionWithTitle:@"Wrap up"
                                        style:UIAlertActionStyleDefault
                                      handler:^(UIAlertAction * _Nonnull action) {
    // TODO
                                      }]];
  [self presentViewController:c animated:YES completion:nil];
}

#pragma mark - Setup

- (void)refillActiveQueue {
  while (self.activeQueue.count < kActiveQueueSize &&
         self.reviewQueue.count != 0) {
    const NSUInteger i = arc4random_uniform((uint32_t)self.reviewQueue.count);
    ReviewItem * item = [self.reviewQueue objectAtIndex:i];
    [self.reviewQueue removeObjectAtIndex:i];
    [self.activeQueue addObject:item];
  }
}

- (void)randomTask {
  // Update the progress labels.
  if (self.tasksAnswered == 0) {
    self.successRateLabel.text = @"100%";
  } else {
    self.successRateLabel.text = [NSString stringWithFormat:@"%d%%",
                                  (int)(self.tasksAnsweredCorrectly / self.tasksAnswered)];
  }
  int queueLength = (int)(self.activeQueue.count + self.reviewQueue.count);
  self.doneLabel.text = [NSString stringWithFormat:@"%d", self.reviewsCompleted];
  self.queueLabel.text = [NSString stringWithFormat:@"%d", queueLength];
  
  // Update the progress bar.
  int totalLength = queueLength + self.reviewsCompleted;
  if (totalLength == 0) {
    self.progressBar.progress = 0.0;
  } else {
    self.progressBar.progress = (double)(self.reviewsCompleted) / totalLength;
  }
  
  // Choose a random task from the active queue.
  if (self.activeQueue.count == 0) {
    return;
  }
  _activeTaskIndex = arc4random_uniform((uint32_t)self.activeQueue.count);
  _activeTask = self.activeQueue[self.activeTaskIndex];
  _activeSubject = [self.dataLoader loadSubject:self.activeTask.assignment.subjectId];
  
  // Choose whether to ask the meaning or the reading.
  if (self.activeTask.passedMeaning) {
    _activeTaskType = kWKTaskTypeReading;
  } else if (self.activeTask.passedReading) {
    _activeTaskType = kWKTaskTypeMeaning;
  } else {
    _activeTaskType = (WKTaskType)arc4random_uniform(kWKTaskType_Max);
  }
  
  // Fill the question labels.
  NSString *subjectTypePrompt;
  NSString *taskTypePrompt;
  NSArray *questionGradient;
  NSArray *promptGradient;
  UIColor *promptTextColor;
  
  switch (self.activeTask.assignment.subjectType) {
    case WKSubject_Type_Kanji:
      subjectTypePrompt = @"Kanji";
      questionGradient = kKanjiGradient;
      break;
    case WKSubject_Type_Radical:
      subjectTypePrompt = @"Radical";
      questionGradient = kRadicalGradient;
      break;
    case WKSubject_Type_Vocabulary:
      subjectTypePrompt = @"Vocabulary";
      questionGradient = kVocabularyGradient;
      break;
  }
  switch (self.activeTaskType) {
    case kWKTaskTypeMeaning:
      taskTypePrompt = @"Meaning";
      promptGradient = kMeaningGradient;
      promptTextColor = kMeaningTextColor;
      break;
    case kWKTaskTypeReading:
      taskTypePrompt = @"Reading";
      promptGradient = kReadingGradient;
      promptTextColor = kReadingTextColor;
      break;
    case kWKTaskType_Max:
      assert(false);
  }
  
  UIFont *boldFont = [UIFont boldSystemFontOfSize:self.promptLabel.font.pointSize];
  NSMutableAttributedString *prompt = [[NSMutableAttributedString alloc] initWithString:
                                       [NSString stringWithFormat:@"%@ %@",
                                        subjectTypePrompt, taskTypePrompt]];
  [prompt setAttributes:@{NSFontAttributeName: boldFont}
                  range:NSMakeRange(prompt.length - taskTypePrompt.length, taskTypePrompt.length)];
  
  [UIView animateWithDuration:0.2f animations:^{
    [self.promptLabel setAttributedText:prompt];
    [self.questionLabel setText:self.activeSubject.japanese];
    [self.correctAnswerLabel setHidden:YES];
    _questionGradient.colors = questionGradient;
    _promptGradient.colors = promptGradient;
    _promptLabel.textColor = promptTextColor;
  }];
}

#pragma mark - Answering

- (void)submit {
  WKAnswerCheckerResult result = CheckAnswer(_answerField.text, _activeSubject, _activeTaskType);
  NSLog(@"Result %d", result);
}

- (IBAction)submitButtonPressed:(id)sender {
  [self submit];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  [self submit];
  return YES;
}

- (IBAction)backgroundTouched:(id)sender {
  [self.view endEditing:NO];
}

@end

