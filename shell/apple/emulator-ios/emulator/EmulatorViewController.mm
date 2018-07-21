//
//  EmulatorViewController.m
//  emulator
//
//  Created by Karen Tsai (angelXwind) on 2014/3/5.
//  Copyright (c) 2014 Karen Tsai (angelXwind). All rights reserved.
//

#import "EmulatorViewController.h"
#import <OpenGLES/ES2/glext.h>

#include "types.h"
#include "profiler/profiler.h"
#include "cfg/cfg.h"
#include "rend/TexCache.h"
#include "hw/maple/maple_devs.h"
#include "hw/maple/maple_if.h"
#import <sys/kdebug_signpost.h>

extern u16 kcode[4];
extern u32 vks[4];
extern s8 joyx[4],joyy[4];
extern u8 rt[4],lt[4];

@interface EmulatorViewController () {
}

@property (strong, nonatomic) EAGLContext *context;
@property (strong, nonatomic) GLKBaseEffect *effect;

- (void)setupGL;
- (void)tearDownGL;
- (void)emuThread;

@end

//who has time for headers
extern int screen_width,screen_height;
bool rend_single_frame();
bool gles_init();
extern "C" int reicast_main(int argc, char* argv[]);


#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>

void move_pthread_to_realtime_scheduling_class(pthread_t pthread)
{
	mach_timebase_info_data_t timebase_info;
	mach_timebase_info(&timebase_info);

	const uint64_t NANOS_PER_MSEC = 1000000ULL;
	double clock2abs = ((double)timebase_info.denom / (double)timebase_info.numer) * NANOS_PER_MSEC;

	thread_time_constraint_policy_data_t policy;
	policy.period      = 0;
	policy.computation = (uint32_t)(5 * clock2abs); // 5 ms of work
	policy.constraint  = (uint32_t)(10 * clock2abs);
	policy.preemptible = FALSE;

	int kr = thread_policy_set(pthread_mach_thread_np(pthread_self()),
							   THREAD_TIME_CONSTRAINT_POLICY,
							   (thread_policy_t)&policy,
							   THREAD_TIME_CONSTRAINT_POLICY_COUNT);
	if (kr != KERN_SUCCESS) {
		mach_error("thread_policy_set:", kr);
		exit(1);
	}
}

void MakeCurrentThreadRealTime()
{
	move_pthread_to_realtime_scheduling_class(pthread_self());
}

@implementation EmulatorViewController

-(void)emuThread
{
//    #if !TARGET_OS_SIMULATOR
    install_prof_handler(1);
 //   #endif
    
	char *Args[3];
	const char *P;

	P = (const char *)[self.diskImage UTF8String];
	Args[0] = "dc";
	Args[1] = "-config";
	Args[2] = P&&P[0]? (char *)malloc(strlen(P)+32):0;

	if(Args[2])
	{
		strcpy(Args[2],"config:image=");
		strcat(Args[2],P);
	}

	MakeCurrentThreadRealTime();

	reicast_main(Args[2]? 3:1,Args);
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	
	self.controllerView = [[PadViewController alloc] initWithNibName:@"PadViewController" bundle:nil];

    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];

    if (!self.context) {
        NSLog(@"Failed to create ES context");
    }
    
    self.emuView = (EmulatorView *)self.view;
    self.emuView.context = self.context;
    self.emuView.drawableDepthFormat = GLKViewDrawableDepthFormat24;

	[self setPreferredFramesPerSecond:50.0];
	[self.controllerView setControlOutput:self.emuView];
    
    self.connectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([[GCController controllers] count] == 1) {
            [self toggleHardwareController:YES];
        }
    }];
    self.disconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (![[GCController controllers] count]) {
            [self toggleHardwareController:NO];
        }
    }];
    
    if ([[GCController controllers] count]) {
        [self toggleHardwareController:YES];
	}

	[self addChildViewController:self.controllerView];
	self.controllerView.view.frame = self.view.bounds;
	self.controllerView.view.translatesAutoresizingMaskIntoConstraints = YES;
	self.controllerView.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:self.controllerView.view];
	[self.controllerView didMoveToParentViewController:self];

    self.iCadeReader = [[iCadeReaderView alloc] init];
    [self.view addSubview:self.iCadeReader];
    self.iCadeReader.delegate = self;
    self.iCadeReader.active = YES;
	
    [self setupGL];
    
    if (!gles_init())
        die("OPENGL FAILED");
    
    NSThread* myThread = [[NSThread alloc] initWithTarget:self
                                                 selector:@selector(emuThread)
                                                   object:nil];
    [myThread start];  // Actually create the thread
}

- (void)dealloc
{
    [self tearDownGL];
    
    if ([EAGLContext currentContext] == self.context) {
        [EAGLContext setCurrentContext:nil];
    }
}

//- (void)didReceiveMemoryWarning
//{
//    [super didReceiveMemoryWarning];
//
//    if ([self isViewLoaded] && ([[self view] window] == nil)) {
//        self.view = nil;
//
//        [self tearDownGL];
//
//        if ([EAGLContext currentContext] == self.context) {
//            [EAGLContext setCurrentContext:nil];
//        }
//        self.context = nil;
//    }
//
//    // Dispose of any resources that can be recreated.
//}

- (void)setupGL
{
    [EAGLContext setCurrentContext:self.context];
    
}

- (void)tearDownGL
{
    [EAGLContext setCurrentContext:self.context];
    
}

#pragma mark - GLKView and GLKViewController delegate methods

- (void)update
{

}

- (void)toggleHardwareController:(BOOL)useHardware {
    if (useHardware) {
		[self.controllerView hideController];
        self.gController = [GCController controllers][0];
        if (self.gController.gamepad) {
            [self.gController.gamepad.buttonA setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_a];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_a];
				}
            }];
            [self.gController.gamepad.buttonB setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_b];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_b];
				}
            }];
            [self.gController.gamepad.buttonX setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_x];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_x];
				}
            }];
            [self.gController.gamepad.buttonY setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_y];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_y];
				}
            }];
            [self.gController.gamepad.dpad setValueChangedHandler:^(GCControllerDirectionPad *dpad, float xValue, float yValue){
				if (dpad.right.isPressed) {
					[self.emuView handleKeyDown:self.controllerView.img_dpad_r];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_r];
				}
				if (dpad.left.isPressed) {
					[self.emuView handleKeyDown:self.controllerView.img_dpad_l];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_l];
				}
				if (dpad.up.isPressed) {
					[self.emuView handleKeyDown:self.controllerView.img_dpad_u];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_u];
				}
				if (dpad.down.isPressed) {
					[self.emuView handleKeyDown:self.controllerView.img_dpad_d];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_d];
				}
            }];

			// Right shoulder for start
			[self.gController.extendedGamepad.rightShoulder setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_rt];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_rt];
				}
			}];

			[self.gController.extendedGamepad.leftThumbstick.xAxis setValueChangedHandler:^(GCControllerAxisInput *axis, float value){
				s8 v=(s8)(value*256) - 127; //-127 ... + 127 range

				NSLog(@"Joy X: %i", v);
				joyx[0] = v;
			}];
			[self.gController.extendedGamepad.leftThumbstick.yAxis setValueChangedHandler:^(GCControllerAxisInput *axis, float value){
				s8 v=(s8)(value*256) - 127; //-127 ... + 127 range

				NSLog(@"Joy Y: %i", v);
				joyy[0] = v;
			}];
            //Add controller pause handler here
        }
        if (self.gController.extendedGamepad) {
            [self.gController.extendedGamepad.buttonA setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_a];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_a];
				}
            }];
            [self.gController.extendedGamepad.buttonB setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_b];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_b];
				}
            }];
            [self.gController.extendedGamepad.buttonX setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_x];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_x];
				}
            }];
            [self.gController.extendedGamepad.buttonY setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_abxy_y];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_abxy_y];
				}
            }];

			// Right shoulder for start
			[self.gController.extendedGamepad.rightShoulder setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_rt];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_rt];
				}
			}];

			[self.gController.extendedGamepad.leftShoulder setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_lt];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_lt];
				}
			}];

			[self.gController.extendedGamepad.rightTrigger setValueChangedHandler:^(GCControllerButtonInput *button, float value, BOOL pressed) {
				if (pressed && value >= 0.1) {
					[self.emuView handleKeyDown:self.controllerView.img_start];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_start];
				}
			}];


            [self.gController.extendedGamepad.dpad setValueChangedHandler:^(GCControllerDirectionPad *dpad, float xValue, float yValue){
				if (dpad.right.isPressed) {
					 [self.emuView handleKeyDown:self.controllerView.img_dpad_r];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_r];
				}
				if (dpad.left.isPressed) {
					[self.emuView handleKeyDown:self.controllerView.img_dpad_l];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_l];
				}
				if (dpad.up.isPressed) {
					[self.emuView handleKeyDown:self.controllerView.img_dpad_u];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_u];
				}
				if (dpad.down.isPressed) {
					[self.emuView handleKeyDown:self.controllerView.img_dpad_d];
				} else {
					[self.emuView handleKeyUp:self.controllerView.img_dpad_d];
				}
            }];
            [self.gController.extendedGamepad.leftThumbstick.xAxis setValueChangedHandler:^(GCControllerAxisInput *axis, float value){
				s8 v=(s8)(value*127); //-127 ... + 127 range

				NSLog(@"Joy X: %i", v);
				joyx[0] = v;
            }];
            [self.gController.extendedGamepad.leftThumbstick.yAxis setValueChangedHandler:^(GCControllerAxisInput *axis, float value){
				s8 v=(s8)(value*127); //-127 ... + 127 range

				NSLog(@"Joy Y: %i", v);
				joyy[0] = v;
            }];
        }
    } else {
        self.gController = nil;
		[self.controllerView showController:self.view];
    }
}


- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    kdebug_signpost_start(10, 0, 0, 0, 0);
	screen_width = view.drawableWidth;
    screen_height = view.drawableHeight;

    glClearColor(0.65f, 0.65f, 0.65f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    while(!rend_single_frame()) ;
	kdebug_signpost_end(10, 0, 0, 0, 0);
}


@end
